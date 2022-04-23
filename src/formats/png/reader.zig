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
            var palette: []png.PaletteEntry = .{};
            var trnsData = TRNSData{ .Unset = undefined };

            while (true) {
                var chunk = try self.rawReader.readStruct(png.ChunkHeader);

                switch (chunk.type) {
                    asU32("IHDR") => {
                        return error.InvalidData;
                    },
                    asU32("IEND") => {
                        _ = self.rawReader.readInt(); // Read and ignore the crc
                        break;
                    },
                    asU32("IDAT") => {
                        //var result = PixelStorage.init(allocator, pixelFormat, header.width() * header.height());
                        self.readAllData(chunk.length(), allocator, options);
                    },
                    asU32("PLTE") => {
                        if (!header.allowsPalette()) return error.InvalidData;
                        if (palette.len > 0) return error.InvalidData;
                        // TODO if IDAT already found ignore this palette
                        // We ignore if tRNS is already found
                        var chunkLength = chunk.length();
                        if (chunkLength % 3 != 0) return error.InvalidData;
                        var length = chunkLength / 3;
                        if (length > header.maxPaletteSize()) return error.InvalidData;
                        if (!isFromFile) {
                            palette = std.mem.bytesAsSlice(png.PaletteType, try self.rawReader.readNoAlloc(chunkLength));
                        } else {
                            palette = options.tempAllocator.?.alloc(png.PaletteEntry, length);
                            try self.rawReader.read(palette);
                        }

                        var expectedCrc = try self.rawReader.readIntBig();
                        var actualCrc = Crc32.hash(mem.sliceAsBytes(palette));
                        if (expectedCrc != actualCrc) return error.InvalidData;
                    },
                    asU32("tRNS") => {
                        // TODO if IDAT already found ignore this chunk
                        if (!options.decodeTransparencyToAlpha) {
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

        fn readTrnsChunk(self: *Self, chunkLength: u32, header: *const png.HeaderData, options: *const png.ReaderOptions) TRNSData {
            // We will allow multiple tRNS chunks and load the last one
            // We ignore if we encounter this chunk with colorType that already has alpha
            var trnsData = TRNSData{ .unset = undefined };
            switch (header.colorType) {
                .Grayscale => {
                    if (chunkLength == 2) {
                        trnsData = .{ .Gray = try self.rawReader.readIntBig(u16) };
                    } else {
                        try self.rawReader.readNoAlloc(chunkLength); // Skip invalid
                    }
                },
                .Indexed => {
                    if (chunkLength <= header.maxPaletteSize()) {
                        trnsData = .{ .IndexAlpha = options.tempAllocator.?.alloc(u8, chunkLength) };
                        try self.rawReader.read(trnsData.IndexAlpha);
                    } else {
                        try self.rawReader.readNoAlloc(chunkLength); // Skip invalid
                    }
                },
                .RgbColor => {
                    if (chunkLength == @sizeOf(color.Rgb48)) {
                        trnsData = .{ .Rgb = try self.rawReader.readStruct(color.Rgb48).* };
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

        fn readAllData(self: *Self, firstChunkLength: u32, options: *const png.ReaderOptions) void {
            // decompressor.zig:294 claims to use 300KiB at most from provided allocator.
            // Original zlib claims it only needs 44KiB so next task is to rewrite zig zlib :).
            var idatReader: IDATReader = .{ .context = IDatChunksReader.init(&self.reader, firstChunkLength) };
            _ = try std.compress.zlib.zlibStream(options.tempAllocator, idatReader);
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
