const std = @import("std");
const png = @import("types.zig");
const imgio = @import("../../io.zig");
const utils = @import("../../utils.zig");
const color = @import("../../color.zig");
const PixelStorage = @import("../../pixel_storage.zig").PixelStorage;
const PixelFormat = @import("../../pixel_format.zig").PixelFormat;
const bigToNative = std.mem.bigToNative;
const ImageReader = imgio.ImageReader;
const ImageParsingError = png.ImageParsingError;
const mem = std.mem;
const File = std.fs.File;
const Crc32 = std.hash.Crc32;
const Allocator = std.mem.Allocator;

const FileReader = Reader(true);
const BufferReader = Reader(false);
const RawFileReader = imgio.FileReader;
const RawBufferReader = imgio.BufferReader;

// Png specification: http://www.libpng.org/pub/png/spec/iso/index-object.html

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

    const common = struct {
        pub fn processChunk(id: u32, chunkProcessData: *png.ChunkProcessData) ImageParsingError!void {
            for (chunkProcessData.options.processors) |*processor| {
                if (processor.id == id) {
                    var newFormat = try processor.processChunk(chunkProcessData);
                    std.debug.assert(newFormat.getPixelStride() >= chunkProcessData.currentFormat.getPixelStride());
                    chunkProcessData.currentFormat = newFormat;
                }
            }
        }
    };

    // Provides reader interface for Zlib stream that knows to read consecutive IDAT chunks.
    const IDatChunksReader = struct {
        rawReader: *RawReader,
        processors: []png.ReaderProcessor,
        chunkProcessData: *png.ChunkProcessData,
        crc: Crc32,

        const Self = @This();

        fn init(
            reader: *RawReader,
            processors: []png.ReaderProcessor,
            chunkProcessData: *png.ChunkProcessData,
        ) Self {
            return .{
                .rawReader = reader,
                .processors = processors,
                .chunkProcessData = chunkProcessData,
                .crc = Crc32.init(),
            };
        }

        fn read(self: *Self, dest: []u8) ImageParsingError!usize {
            if (self.chunkProcessData.chunkLength == 0) return 0;
            var newDest = dest;

            var chunkLength = self.chunkProcessData.chunkLength;

            var toRead = newDest.len;
            if (toRead > chunkLength) toRead = chunkLength;
            var readCount = try self.rawReader.read(newDest[0..toRead]);
            self.chunkProcessData.chunkLength -= @intCast(u32, readCount);
            self.crc.update(newDest[0..readCount]);

            if (chunkLength == 0) {
                // First read and check CRC of just finished chunk
                const expectedCrc = try self.rawReader.readIntBig(u32);
                if (self.crc.final() != expectedCrc) return error.InvalidData;

                try common.processChunk(png.HeaderData.ChunkTypeId, self.chunkProcessData);

                self.crc = Crc32.init();

                // Try to load the next IDAT chunk
                var chunk = try self.rawReader.readStruct(png.ChunkHeader);
                if (chunk.type == png.HeaderData.ChunkTypeId) {
                    self.chunkProcessData.chunkLength = chunk.length();
                } else {
                    // Return to the start of the next chunk so code in main struct can read it
                    try self.rawReader.seekBy(-@sizeOf(png.ChunkHeader));
                }
            }

            return readCount;
        }
    };

    const IDATReader = std.io.Reader(*IDatChunksReader, ImageParsingError, IDatChunksReader.read);

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
            try self.loadWithHeader(&header, allocator, options);
        }

        fn asU32(str: *const [4:0]u8) u32 {
            return std.mem.bytesToValue(u32, str);
        }

        pub fn loadWithHeader(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: png.ReaderOptions,
        ) ImageParsingError!void {
            if (options.tempAllocator != null) {
                try doLoad(self, header, allocator, &options);
            } else {
                try prepareTmpAllocatorAndLoad(self, header, allocator, &options);
            }
        }

        pub fn prepareTmpAllocatorAndLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const png.ReaderOptions,
        ) ImageParsingError!void {
            var tmpBuffer: [500 * 1024]u8 = undefined;
            var newOptions = options.*;
            newOptions.tempAllocator = std.heap.FixedBufferAllocator.init(tmpBuffer[0..]).allocator();
            try doLoad(self, header, allocator, &newOptions);
        }

        fn doLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const png.ReaderOptions,
        ) ImageParsingError!void {
            var palette: []color.Rgb24 = &[_]color.Rgb24{};
            var dataFound = false;

            var chunkProcessData = png.ChunkProcessData{
                .rawReader = ImageReader.wrap(self.rawReader),
                .chunkLength = @sizeOf(png.HeaderData),
                .currentFormat = header.getPixelFormat(),
                .header = header,
                .options = options,
            };
            try common.processChunk(png.HeaderData.ChunkTypeId, &chunkProcessData);

            while (true) {
                var chunk = try self.rawReader.readStruct(png.ChunkHeader);

                switch (chunk.type) {
                    asU32("IHDR") => {
                        return error.InvalidData; // We already processed IHDR so another one is an error
                    },
                    asU32("IEND") => {
                        if (!dataFound) return error.InvalidData;
                        _ = try self.rawReader.readInt(u32); // Read and ignore the crc
                        chunkProcessData.chunkLength = chunk.length();
                        try common.processChunk(chunk.type, &chunkProcessData);
                        break;
                    },
                    asU32("IDAT") => {
                        if (dataFound) return error.InvalidData;
                        if (header.colorType == .Indexed and palette.len == 0) return error.InvalidData;
                        dataFound = true;
                        chunkProcessData.chunkLength = chunk.length();
                        _ = try self.readAllData(header, palette, allocator, options, &chunkProcessData);
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
                            _ = try self.rawReader.readNoAlloc(chunkLength + @sizeOf(u32));
                        } else {
                            if (!isFromFile) {
                                var paletteBytes = try self.rawReader.readNoAlloc(chunkLength);
                                palette = std.mem.bytesAsSlice(png.PaletteType, paletteBytes);
                            } else {
                                palette = try options.tempAllocator.?.alloc(color.Rgb24, length);
                                var filled = try self.rawReader.read(mem.sliceAsBytes(palette));
                                if (filled != palette.len * @sizeOf(color.Rgb24)) return error.EndOfStream;
                            }

                            var expectedCrc = try self.rawReader.readIntBig(u32);
                            var actualCrc = Crc32.hash(mem.sliceAsBytes(palette));
                            if (expectedCrc != actualCrc) return error.InvalidData;
                            chunkProcessData.chunkLength = chunkLength;
                            try common.processChunk(chunk.type, &chunkProcessData);
                        }
                    },
                    else => {
                        chunkProcessData.chunkLength = chunk.length();
                        try common.processChunk(chunk.type, &chunkProcessData);
                    },
                }
            }
        }

        fn readAllData(
            self: *Self,
            header: *const png.HeaderData,
            palette: []color.Rgb24,
            allocator: Allocator,
            options: *const png.ReaderOptions,
            chunkProcessData: *png.ChunkProcessData,
        ) ImageParsingError!PixelStorage {
            // decompressor.zig:294 claims to use 300KiB at most from provided allocator.
            // Original zlib claims it only needs 44KiB so next task is to rewrite zig zlib :).

            var destFormat = chunkProcessData.currentFormat;
            const width = header.width();
            const height = header.height();
            var result = try PixelStorage.init(allocator, destFormat, width * height);
            var idatChunksReader = IDatChunksReader.init(&self.rawReader, options.processors, chunkProcessData);
            var idatReader: IDATReader = .{ .context = &idatChunksReader };
            var decompressStream = std.compress.zlib.zlibStream(options.tempAllocator.?, idatReader) catch return error.InvalidData;

            switch (result) {
                .Index1 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                    try processPalette(options.processors, data.palette);
                },
                .Index2 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                    try processPalette(options.processors, data.palette);
                },
                .Index4 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                    try processPalette(options.processors, data.palette);
                },
                .Index8 => |data| {
                    for (palette) |entry, n| {
                        data.palette[n] = entry.toColorf32();
                    }
                    try processPalette(options.processors, data.palette);
                },
                else => {},
            }

            var dest = result.pixelsAsBytes();

            // For defiltering we need to keep two rows in memory so we allocate space for that
            var channelCount = header.channelCount();
            const filterStride = (header.bitDepth + 7) / 8 * channelCount; // 1 to 8 bytes
            const lineBytes = header.lineBytes();
            const virtualLineBytes = lineBytes + filterStride;
            var tmpBuffer = try allocator.alloc(u8, 2 * virtualLineBytes);
            defer allocator.free(tmpBuffer);
            mem.set(u8, tmpBuffer, 0);
            var prevRow = tmpBuffer[0..virtualLineBytes];
            var currentRow = tmpBuffer[virtualLineBytes..];
            const resultLineBytes = @intCast(u32, dest.len / height);
            const pixelStride = resultLineBytes / width;
            std.debug.assert(pixelStride == destFormat.getPixelStride());

            var i: u32 = 0;
            while (i < height) : (i += 1) {
                var filled = decompressStream.read(currentRow[filterStride - 1 ..]) catch return error.InvalidData;
                if (filled != lineBytes + 1) return error.EndOfStream;
                try defilter(currentRow, prevRow, filterStride);
                currentRow[filterStride - 1] = 0; // zero out the filter byte

                var destRow = dest[0..resultLineBytes];
                dest = dest[resultLineBytes..];

                // Spread raw data into destRow
                var pix: u32 = 0;
                var srcPix: u32 = filterStride;
                switch (header.bitDepth) {
                    1, 2, 4 => {
                        while (pix < resultLineBytes) {
                            // colorType must be Grayscale or Indexed
                            var shift = @intCast(i4, 8 - header.bitDepth);
                            var mask = @as(u8, 0xff) << @intCast(u3, shift);

                            while (shift > 0 and pix < resultLineBytes) : (shift -= @intCast(i4, header.bitDepth)) {
                                destRow[pix] = (currentRow[srcPix] & mask) >> @intCast(u3, shift);
                                pix += pixelStride;
                            }
                            srcPix += 1;
                        }
                    },
                    8 => {
                        while (pix < resultLineBytes) : (pix += pixelStride) {
                            var c: u32 = 0;
                            while (c < channelCount) : (c += 1) {
                                destRow[pix + c] = currentRow[srcPix + c];
                            }
                            srcPix += channelCount;
                        }
                    },
                    16 => {
                        var currentRow16 = mem.bytesAsSlice(u16, currentRow);
                        var destRow16 = mem.bytesAsSlice(u16, destRow);
                        const pixelStride16 = pixelStride / 2;
                        while (pix < destRow16.len) : (pix += pixelStride16) {
                            var c: u32 = 0;
                            while (c < channelCount) : (c += 1) {
                                destRow16[pix + c] = currentRow16[srcPix + c];
                            }
                            srcPix += channelCount;
                        }
                    },
                    else => unreachable,
                }

                var resultFormat = try process(destRow, header.getPixelFormat(), destFormat, header, options);
                if (resultFormat != destFormat) return error.InvalidData;

                var tmp = prevRow;
                prevRow = currentRow;
                currentRow = tmp;
            }

            return result;
        }

        fn processPalette(processors: []png.ReaderProcessor, palette: []color.Colorf32) ImageParsingError!void {
            var processData = png.PaletteProcessData{ .palette = palette };
            for (processors) |*processor| {
                try processor.processPalette(&processData);
            }
        }

        fn process(
            destRow: []u8,
            srcFormat: PixelFormat,
            destFormat: PixelFormat,
            header: *const png.HeaderData,
            options: *const png.ReaderOptions,
        ) ImageParsingError!PixelFormat {
            var processData = png.RowProcessData{
                .destRow = destRow,
                .srcFormat = srcFormat,
                .destFormat = destFormat,
                .header = header,
                .options = options,
            };
            var resultFormat = srcFormat;
            for (options.processors) |*processor| {
                resultFormat = try processor.processDataRow(&processData);
                processData.srcFormat = resultFormat;
            }
            return resultFormat;
        }

        fn defilter(currentRow: []u8, prevRow: []u8, filterStride: u8) ImageParsingError!void {
            const filterByte = currentRow[filterStride - 1];
            if (filterByte > @enumToInt(png.FilterType.Paeth)) return error.InvalidData;
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
                    const a = currentRow[x - filterStride];
                    const b = prevRow[x];
                    const c = prevRow[x - filterStride];
                    var pa: i32 = b - c;
                    var pb: i32 = a - c;
                    var pc: i32 = pa + pb;
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
