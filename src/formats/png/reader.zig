const std = @import("std");
const png = @import("types.zig");
const imgio = @import("../../io.zig");
const utils = @import("../../utils.zig");
const color = @import("../../color.zig");
const PixelStorage = @import("../../pixel_storage.zig").PixelStorage;
const bigToNative = std.mem.bigToNative;
const ImageReader = imgio.ImageReader16;
const mem = std.mem;
const File = std.io.File;
const Crc32 = std.hash.Crc32;
const Allocator = std.mem.Allocator;

const FileReader = Reader(true);
const BufferReader = Reader(false);
const RawFileReader = imgio.FileReader14; // 2^14 = 16K buffer
const RawBufferReader = imgio.BufferReader;

// Png specification: http://www.libpng.org/pub/png/spec/iso/index-object.html

pub const ImageParsingError = error{InvalidData} || imgio.ImageReadError;

pub fn fromFile(file: File) FileReader {
    return .{
        .rawReader = RawFileReader.init(file),
    };
}

pub fn fromMemory(buffer: []const u8) BufferReader {
    return .{
        .rawReader = RawBufferReader.init(buffer),
    };
}

fn Reader(comptime isFromFile: bool) type {
    const RawReader = if (isFromFile) RawFileReader else RawBufferReader;

    // Provides reader interface for Zlib stream that knows to read consecutive IDAT chunks.
    const IDatChunksReader = struct {
        rawReader: *RawReader,
        chunkBytes: usize,
        crc: Crc32,

        const Self = @This();

        fn init(reader: *RawReader, firstChunkLength: u32) Self {
            return .{ .rawReader = reader, .chunkBytes = firstChunkLength, .crc = Crc32.init() };
        }

        fn read(self: *Self, dest: []u8) ImageParsingError!usize {
            if (self.chunkBytes == 0) return 0;
            var newDest = dest;

            var toRead = newDest.len;
            if (toRead > self.chunkBytes) toRead = self.chunkBytes;
            var readCount = try self.rawReader.read(newDest[0..toRead]);
            self.chunkBytes -= readCount;
            self.crc.update(newDest[0..readCount]);

            if (self.chunkBytes == 0) {
                // First read and check CRC of just finished chunk
                const expectedCrc = try self.rawReader.readIntBig(u32);
                if (self.crc.final() != expectedCrc) return error.InvalidData;
                self.crc = Crc32.init();

                // Try to load the next IDAT chunk
                var chunk = try self.rawReader.readStruct(png.ChunkHeader);
                if (chunk.type == std.mem.bytesToValue(u32, "IDAT")) {
                    self.chunkBytes = chunk.length();
                } else {
                    // Return to the start of the next chunk so code in main struct can read it
                    try self.rawReader.seekBy(-@sizeOf(png.ChunkHeader));
                }
            }

            return readCount;
        }
    };

    const IDATReader = std.io.Reader(*IDatChunksReader, ImageParsingError, IDatChunksReader.read);
    const TRNSData = union(enum) { unset: u0, gray: u16, rgb: color.Rgb48, indexAlpha: []u8 };

    // =========== Main Png reader struct start here ===========
    return struct {
        rawReader: RawReader,

        const Self = @This();

        pub fn loadHeader(self: *Self) ImageParsingError!png.HeaderData {
            var sig = try self.rawReader.readNoAlloc(png.MagicHeader.len);
            if (!mem.eql(u8, sig[0..], png.MagicHeader)) return error.InvalidData;

            var chunk = try self.rawReader.readStruct(png.ChunkHeader);
            if (chunk.type != png.HeaderData.ChunkTypeId) return error.InvalidData;
            if (chunk.length() != @sizeOf(png.HeaderData)) return error.InvalidData;

            var header = (try self.rawReader.readStruct(png.HeaderData));
            if (!header.isValid()) return error.InvalidData;

            var expectedCrc = try self.rawReader.readIntBig(u32);
            var actualCrc = Crc32.hash(mem.asBytes(header));
            if (expectedCrc != actualCrc) return error.InvalidData;

            return header.*;
        }

        pub fn load(self: *Self, allocator: Allocator, options: png.ReaderOptions) ImageParsingError!void {
            var header = try self.loadHeader();
            try self.loadWithHeader(header, allocator, options);
        }

        fn asU32(str: []const u8) u32 {
            return std.mem.bytesToValue(u32, str);
        }

        pub fn loadWithHeader(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: png.ReaderOptions,
        ) ImageParsingError!void {
            if (options.tempAllocator) {
                doLoad(self, header, allocator, options);
            } else {
                prepareTmpAllocatorAndLoad(self, header, allocator, &options);
            }
        }

        pub fn prepareTmpAllocatorAndLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: png.ReaderOptions,
        ) ImageParsingError!void {
            var tmpBuffer: [500 * 1024]u8 = undefined;
            options.tempAllocator = std.heap.FixedBufferAllocator.init(tmpBuffer);
            doLoad(self, header, allocator, &options);
        }

        fn doLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const png.ReaderOptions,
        ) ImageParsingError!void {
            var palette: []color.Rgb24 = .{};
            var trnsData = TRNSData{ .Unset = undefined };
            var dataFound = false;

            while (true) {
                var chunk = try self.rawReader.readStruct(png.ChunkHeader);

                switch (chunk.type) {
                    asU32("IHDR") => {
                        return error.InvalidData; // We already processed IHDR so another one is an error
                    },
                    asU32("IEND") => {
                        if (!dataFound) return error.InvalidData;
                        _ = self.rawReader.readInt(); // Read and ignore the crc
                        break;
                    },
                    asU32("IDAT") => {
                        if (dataFound) return error.InvalidData;
                        if (header.colorType == .Indexed and palette.len == 0) return error.InvalidData;
                        dataFound = true;
                        _ = try self.readAllData(chunk.length(), header, palette, allocator, options);
                    },
                    asU32("PLTE") => {
                        if (!header.allowsPalette()) return error.InvalidData;
                        if (palette.len > 0) return error.InvalidData;
                        // We ignore if tRNS is already found
                        var chunkLength = chunk.length();
                        if (chunkLength % 3 != 0) return error.InvalidData;
                        var length = chunkLength / 3;
                        if (length > header.maxPaletteSize()) return error.InvalidData;
                        if (dataFound) {
                            // If IDAT was already processed we skip and ignore this palette
                            try self.rawReader.readNoAlloc(chunkLength + @sizeOf(u32));
                        } else {
                            if (!isFromFile) {
                                var paletteBytes = try self.rawReader.readNoAlloc(chunkLength);
                                palette = std.mem.bytesAsSlice(png.PaletteType, paletteBytes);
                            } else {
                                palette = options.tempAllocator.?.alloc(color.Rgb24, length);
                                try self.rawReader.read(palette);
                            }

                            var expectedCrc = try self.rawReader.readIntBig();
                            var actualCrc = Crc32.hash(mem.sliceAsBytes(palette));
                            if (expectedCrc != actualCrc) return error.InvalidData;
                        }
                    },
                    asU32("tRNS") => {
                        if (!options.decodeTransparencyToAlpha or dataFound) {
                            // Just skip this chunk and its crc
                            self.rawReader.readNoAlloc(chunk.length() + @sizeOf(u32));
                        } else {
                            trnsData = self.readTrnsChunk(chunk.length(), header, options);
                        }
                    },
                    else => {},
                }
            }
        }

        fn readTrnsChunk(self: *Self, chunkLength: u32, header: *const png.HeaderData, options: *const png.ReaderOptions) ImageParsingError!TRNSData {
            // We will allow multiple tRNS chunks and load the last one
            // We ignore if we encounter this chunk with colorType that already has alpha
            var trnsData = TRNSData{ .unset = undefined };
            switch (header.colorType) {
                .Grayscale => {
                    if (chunkLength == 2) {
                        trnsData = .{ .gray = try self.rawReader.readIntBig(u16) };
                    } else {
                        try self.rawReader.readNoAlloc(chunkLength); // Skip invalid
                    }
                },
                .Indexed => {
                    if (chunkLength <= header.maxPaletteSize()) {
                        trnsData = .{ .indexAlpha = options.tempAllocator.?.alloc(u8, chunkLength) };
                        try self.rawReader.read(trnsData.indexAlpha);
                    } else {
                        try self.rawReader.readNoAlloc(chunkLength); // Skip invalid
                    }
                },
                .RgbColor => {
                    if (chunkLength == @sizeOf(color.Rgb48)) {
                        trnsData = .{ .rgb = try self.rawReader.readStruct(color.Rgb48).* };
                    } else {
                        try self.rawReader.readNoAlloc(chunkLength); // Skip invalid
                    }
                },
                else => try self.rawReader.readNoAlloc(chunkLength), // Skip invalid
            }
            // Read but ignore Crc since this is not critical chunk
            _ = try self.rawReader.readNoAlloc(@sizeOf(u32));
            return trnsData;
        }

        fn readAllData(
            self: *Self,
            firstChunkLength: u32,
            header: *const png.HeaderData,
            palette: []color.Rgb24,
            allocator: Allocator,
            options: *const png.ReaderOptions,
        ) ImageParsingError!PixelStorage {
            // decompressor.zig:294 claims to use 300KiB at most from provided allocator.
            // Original zlib claims it only needs 44KiB so next task is to rewrite zig zlib :).

            var pixelFormat = header.getPixelFormat();
            const width = header.width();
            const height = header.height();
            var result = PixelStorage.init(allocator, pixelFormat, width * height);
            var idatReader: IDATReader = .{ .context = IDatChunksReader.init(&self.reader, firstChunkLength) };
            var decompressStream = try std.compress.zlib.zlibStream(options.tempAllocator, idatReader);

            switch (result) {
                .Bpp1 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                },
                .Bpp2 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                },
                .Bpp4 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                },
                .Bpp8 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                },
                else => {},
            }

            // For defiltering we need to keep two rows in memory so we allocate space for that
            const filterStride = (header.bitDepth + 7) / 8 * header.channelCount(); // 1 to 8 bytes
            const lineBytes = header.lineBytes();
            const virtualLineBytes = lineBytes + filterStride;
            var twoRowsBuffer = try allocator.alloc(u8, 2 * virtualLineBytes);
            defer allocator.free(twoRowsBuffer);
            mem.set(u8, twoRowsBuffer, 0);
            var prevRow = twoRowsBuffer[0..virtualLineBytes];
            var currentRow = twoRowsBuffer[virtualLineBytes..];

            var i: u32 = 0;
            while (i < height) : (i += 1) {
                decompressStream.read(currentRow[filterStride - 1 ..]);
                defilter(currentRow, prevRow, filterStride);
                currentRow[filterStride - 1] = 0; // zero out the filter byte

                // TODO Process before copy pixels to destination

                var tmp = prevRow;
                prevRow = currentRow;
                currentRow = tmp;
            }

            return result;
        }

        fn defilter(currentRow: []u8, prevRow: []u8, filterStride: u8) ImageParsingError!void {
            const filterByte = currentRow[filterStride - 1];
            if (filterByte >= png.FilterType.Count) return error.InvalidData;
            const filter = @intToEnum(png.FilterType, filterByte);

            var x: u32 = filterStride;
            switch (filter) {
                .None => {},
                .Sub => while (x < currentRow.len) : (x += 1) {
                    currentRow[x] += currentRow[x - filterStride];
                },
                .Up => while (x < currentRow.len) : (x += 1) {
                    currentRow[x] += prevRow[x];
                },
                .Average => while (x < currentRow.len) : (x += 1) {
                    currentRow[x] += (currentRow[x - filterStride] + prevRow[x]) / 2;
                },
                .Paeth => while (x < currentRow.len) : (x += 1) {
                    const a: i32 = currentRow[x - filterStride];
                    const b: i32 = prevRow[x];
                    const c: i32 = prevRow[x - filterStride];
                    var pa = b - c;
                    var pb = a - c;
                    var pc = pa + pb;
                    if (pa < 0) pa = -pa;
                    if (pb < 0) pb = -pb;
                    if (pc < 0) pc = -pc;
                    // zig fmt: off
                    currentRow[x] += if (pa <= pb and pa <= pc) @truncate(u8, a)
                                     else if (pb <= pc) @truncate(u8, b)
                                     else @truncate(u8, c);
                    // zig fmt: on
                },
            }
        }
    };
}

// ********************* TESTS *********************

const expectError = std.testing.expectError;

const validHeaderBuf = png.MagicHeader ++ "\x00\x00\x00\x0d" ++ png.HeaderData.ChunkType ++
    "\x00\x00\x00\xff\x00\x00\x00\x75\x08\x06\x00\x00\x01\xd7\xc0\x29\x6f";

test "loadHeader_valid" {
    const expectEqual = std.testing.expectEqual;
    var reader = fromMemory(validHeaderBuf[0..]);
    var header = try reader.loadHeader();
    try expectEqual(@as(u32, 0xff), header.width());
    try expectEqual(@as(u32, 0x75), header.height());
    try expectEqual(@as(u8, 8), header.bitDepth);
    try expectEqual(png.ColorType.RgbaColor, header.colorType);
    try expectEqual(png.CompressionMethod.Deflate, header.compressionMethod);
    try expectEqual(png.FilterMethod.Adaptive, header.filterMethod);
    try expectEqual(png.InterlaceMethod.Adam7, header.interlaceMethod);
}

test "loadHeader_empty" {
    const buf: [0]u8 = undefined;
    var reader = fromMemory(buf[0..]);
    try expectError(error.EndOfStream, reader.loadHeader());
}

test "loadHeader_badSig" {
    const buf = "asdsdasdasdsads";
    var reader = fromMemory(buf[0..]);
    try expectError(error.InvalidData, reader.loadHeader());
}

test "loadHeader_badChunk" {
    const buf = png.MagicHeader ++ "\x00\x00\x01\x0d" ++ png.HeaderData.ChunkType ++ "asad";
    var reader = fromMemory(buf[0..]);
    try expectError(error.InvalidData, reader.loadHeader());
}

test "loadHeader_shortHeader" {
    const buf = png.MagicHeader ++ "\x00\x00\x00\x0d" ++ png.HeaderData.ChunkType ++ "asad";
    var reader = fromMemory(buf[0..]);
    try expectError(error.EndOfStream, reader.loadHeader());
}

test "loadHeader_invalidHeaderData" {
    var buf: [validHeaderBuf.len]u8 = undefined;
    std.mem.copy(u8, buf[0..], validHeaderBuf[0..]);
    var pos = png.MagicHeader.len + @sizeOf(png.ChunkHeader);

    try testHeaderWithInvalidValue(buf[0..], pos, 0xf0); // width highest bit is 1
    pos += 3;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // width is 0
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0xf0); // height highest bit is 1
    pos += 3;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // height is 0

    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x00); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x07); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x03); // invalid bit depth
    try testHeaderWithInvalidValue(buf[0..], pos, 0x04); // invalid bit depth for rgba color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x02); // invalid bit depth for rgba color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid bit depth for rgba color type
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid color type
    try testHeaderWithInvalidValue(buf[0..], pos, 0x05);
    try testHeaderWithInvalidValue(buf[0..], pos, 0x07);
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid compression method
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x01); // invalid filter method
    pos += 1;
    try testHeaderWithInvalidValue(buf[0..], pos, 0x02); // invalid interlace method
}

fn testHeaderWithInvalidValue(buf: []u8, pos: usize, val: u8) !void {
    var orig = buf[pos];
    buf[pos] = val;
    var reader = fromMemory(buf[0..]);
    try expectError(error.InvalidData, reader.loadHeader());
    buf[pos] = orig;
}
