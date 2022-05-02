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
const RawFileReader = imgio.FileReader;
const RawBufferReader = imgio.BufferReader;

// Png specification: http://www.libpng.org/pub/png/spec/iso/index-object.html

pub const FileReader = Reader(true);
pub const BufferReader = Reader(false);

pub fn fromFile(file: File) FileReader {
    return .{
        .raw_reader = RawFileReader.init(file),
    };
}

pub fn fromMemory(buffer: []const u8) BufferReader {
    return .{
        .raw_reader = RawBufferReader.init(buffer),
    };
}

fn Reader(comptime is_from_file: bool) type {
    const RawReader = if (is_from_file) RawFileReader else RawBufferReader;

    const Common = struct {
        pub fn processChunk(processors: []ReaderProcessor, id: u32, chunk_process_data: *ChunkProcessData) ImageParsingError!void {
            for (processors) |*processor| {
                if (processor.id == id) {
                    var new_format = try processor.processChunk(chunk_process_data);
                    std.debug.assert(new_format.getPixelStride() >= chunk_process_data.current_format.getPixelStride());
                    chunk_process_data.current_format = new_format;
                }
            }
        }
    };

    // Provides reader interface for Zlib stream that knows to read consecutive IDAT chunks.
    const IDatChunksReader = struct {
        raw_reader: *RawReader,
        processors: []ReaderProcessor,
        chunk_process_data: *ChunkProcessData,
        crc: Crc32,

        const Self = @This();

        fn init(
            reader: *RawReader,
            processors: []ReaderProcessor,
            chunk_process_data: *ChunkProcessData,
        ) Self {
            return .{
                .raw_reader = reader,
                .processors = processors,
                .chunk_process_data = chunk_process_data,
                .crc = Crc32.init(),
            };
        }

        fn read(self: *Self, dest: []u8) ImageParsingError!usize {
            if (self.chunk_process_data.chunk_length == 0) return 0;
            var new_dest = dest;

            var chunk_length = self.chunk_process_data.chunk_length;

            var to_read = new_dest.len;
            if (to_read > chunk_length) to_read = chunk_length;
            var read_count = try self.raw_reader.read(new_dest[0..to_read]);
            self.chunk_process_data.chunk_length -= @intCast(u32, read_count);
            self.crc.update(new_dest[0..read_count]);

            if (chunk_length == 0) {
                // First read and check CRC of just finished chunk
                const expected_crc = try self.raw_reader.readIntBig(u32);
                if (self.crc.final() != expected_crc) return error.InvalidData;

                try Common.processChunk(self.processors, png.HeaderData.chunk_type_id, self.chunk_process_data);

                self.crc = Crc32.init();

                // Try to load the next IDAT chunk
                var chunk = try self.raw_reader.readStruct(png.ChunkHeader);
                if (chunk.type == png.HeaderData.chunk_type_id) {
                    self.chunk_process_data.chunk_length = chunk.length();
                } else {
                    // Return to the start of the next chunk so code in main struct can read it
                    try self.raw_reader.seekBy(-@sizeOf(png.ChunkHeader));
                }
            }

            return read_count;
        }
    };

    const IDATReader = std.io.Reader(*IDatChunksReader, ImageParsingError, IDatChunksReader.read);

    // =========== Main Png reader struct start here ===========
    return struct {
        raw_reader: RawReader,

        const Self = @This();

        pub fn loadHeader(self: *Self) ImageParsingError!png.HeaderData {
            var sig = try self.raw_reader.readNoAlloc(png.magic_header.len);
            if (!mem.eql(u8, sig[0..], png.magic_header)) return error.InvalidData;

            var chunk = try self.raw_reader.readStruct(png.ChunkHeader);
            if (chunk.type != png.HeaderData.chunk_type_id) return error.InvalidData;
            if (chunk.length() != @sizeOf(png.HeaderData)) return error.InvalidData;

            var header = (try self.raw_reader.readStruct(png.HeaderData));
            if (!header.isValid()) return error.InvalidData;

            var expected_crc = try self.raw_reader.readIntBig(u32);
            var actual_crc = Crc32.hash(mem.asBytes(header));
            if (expected_crc != actual_crc) return error.InvalidData;

            return header.*;
        }

        /// Loads the png image using the given allocator and options.
        /// The options allow you to pass in a custom allocator for temporary allocations.
        /// By default it will use a fixed buffer on stack for temporary allocations.
        /// You can also pass in a custom array of chunk processors. By default empty array
        /// will mean you want a set of default processors which at the moment are:
        /// 1. tRNS processor that decodes the tRNS chunk if it exists into an alpha channel
        /// 2. PLTE processor that decodes the indexed image with a palette into RGB image.
        /// If you really don't want any processing pass in the `no_processors` in processors array.
        pub fn load(self: *Self, allocator: Allocator, options: ReaderOptions) ImageParsingError!void {
            var header = try self.loadHeader();
            try self.loadWithHeader(&header, allocator, options);
        }

        /// Loads the png image for which the header has already been loaded.
        /// For options param description look at the load method docs.
        pub fn loadWithHeader(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: ReaderOptions,
        ) ImageParsingError!void {
            var opts = options;
            // Empty processors array means you want to use defualt processors.
            if (options.processors.len == 0) {
                var trnsProcessor = TrnsProcessor{};
                opts.processors = &.{trnsProcessor.processor()};
            }
            if (options.temp_allocator != null) {
                try doLoad(self, header, allocator, &opts);
            } else {
                try prepareTmpAllocatorAndLoad(self, header, allocator, &opts);
            }
        }

        pub fn prepareTmpAllocatorAndLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const ReaderOptions,
        ) ImageParsingError!void {
            // decompressor.zig:294 claims to use 300KiB at most from provided allocator.
            // Original zlib claims it only needs 44KiB so next task is to rewrite zig zlib :).
            var tmp_buffer: [500 * 1024]u8 = undefined;
            var new_options = options.*;
            new_options.temp_allocator = std.heap.FixedBufferAllocator.init(tmp_buffer[0..]).allocator();
            try doLoad(self, header, allocator, &new_options);
        }

        fn asU32(str: *const [4:0]u8) u32 {
            return std.mem.bytesToValue(u32, str);
        }

        fn doLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const ReaderOptions,
        ) ImageParsingError!void {
            var palette: []color.Rgb24 = &[_]color.Rgb24{};
            var data_found = false;

            var chunk_process_data = ChunkProcessData{
                .raw_reader = ImageReader.wrap(self.raw_reader),
                .chunk_length = @sizeOf(png.HeaderData),
                .current_format = header.getPixelFormat(),
                .header = header,
                .temp_allocator = options.temp_allocator.?,
            };
            try Common.processChunk(options.processors, png.HeaderData.chunk_type_id, &chunk_process_data);

            while (true) {
                var chunk = try self.raw_reader.readStruct(png.ChunkHeader);

                switch (chunk.type) {
                    asU32("IHDR") => {
                        return error.InvalidData; // We already processed IHDR so another one is an error
                    },
                    asU32("IEND") => {
                        if (!data_found) return error.InvalidData;
                        _ = try self.raw_reader.readInt(u32); // Read and ignore the crc
                        chunk_process_data.chunk_length = chunk.length();
                        try Common.processChunk(options.processors, chunk.type, &chunk_process_data);
                        break;
                    },
                    asU32("IDAT") => {
                        if (data_found) return error.InvalidData;
                        if (header.color_type == .indexed and palette.len == 0) return error.InvalidData;
                        data_found = true;
                        chunk_process_data.chunk_length = chunk.length();
                        _ = try self.readAllData(header, palette, allocator, options, &chunk_process_data);
                    },
                    asU32("PLTE") => {
                        if (!header.allowsPalette()) return error.InvalidData;
                        if (palette.len > 0) return error.InvalidData;
                        // We ignore if tRNS is already found
                        var chunk_length = chunk.length();
                        if (chunk_length % 3 != 0) return error.InvalidData;
                        var length = chunk_length / 3;
                        if (length > header.maxPaletteSize()) return error.InvalidData;
                        if (data_found) {
                            // If IDAT was already processed we skip and ignore this palette
                            _ = try self.raw_reader.readNoAlloc(chunk_length + @sizeOf(u32));
                        } else {
                            if (!is_from_file) {
                                var palette_bytes = try self.raw_reader.readNoAlloc(chunk_length);
                                palette = std.mem.bytesAsSlice(png.PaletteType, palette_bytes);
                            } else {
                                palette = try options.temp_allocator.?.alloc(color.Rgb24, length);
                                var filled = try self.raw_reader.read(mem.sliceAsBytes(palette));
                                if (filled != palette.len * @sizeOf(color.Rgb24)) return error.EndOfStream;
                            }

                            var expected_crc = try self.raw_reader.readIntBig(u32);
                            var actual_crc = Crc32.hash(mem.sliceAsBytes(palette));
                            if (expected_crc != actual_crc) return error.InvalidData;
                            chunk_process_data.chunk_length = chunk_length;
                            try Common.processChunk(options.processors, chunk.type, &chunk_process_data);
                        }
                    },
                    else => {
                        chunk_process_data.chunk_length = chunk.length();
                        try Common.processChunk(options.processors, chunk.type, &chunk_process_data);
                    },
                }
            }
        }

        fn readAllData(
            self: *Self,
            header: *const png.HeaderData,
            palette: []color.Rgb24,
            allocator: Allocator,
            options: *const ReaderOptions,
            chunk_process_data: *ChunkProcessData,
        ) ImageParsingError!PixelStorage {
            var dest_format = chunk_process_data.current_format;
            const width = header.width();
            const height = header.height();
            var result = try PixelStorage.init(allocator, dest_format, width * height);
            var idat_chunks_reader = IDatChunksReader.init(&self.raw_reader, options.processors, chunk_process_data);
            var idat_reader: IDATReader = .{ .context = &idat_chunks_reader };
            var decompressStream = std.compress.zlib.zlibStream(options.temp_allocator.?, idat_reader) catch return error.InvalidData;

            if (result.getPallete()) |dest_palette| {
                for (palette) |entry, n| {
                    dest_palette[n] = entry.toColorf32();
                }
                try processPalette(options, dest_palette);
            }

            var dest = result.pixelsAsBytes();

            // For defiltering we need to keep two rows in memory so we allocate space for that
            const filter_stride = (header.bit_depth + 7) / 8 * header.channelCount(); // 1 to 8 bytes
            const line_bytes = header.lineBytes();
            const virtual_line_bytes = line_bytes + filter_stride;
            var tmp_buffer = try allocator.alloc(u8, 2 * virtual_line_bytes);
            defer allocator.free(tmp_buffer);
            mem.set(u8, tmp_buffer, 0);
            var prev_row = tmp_buffer[0..virtual_line_bytes];
            var current_row = tmp_buffer[virtual_line_bytes..];
            const result_line_bytes = @intCast(u32, dest.len / height);
            const pixel_stride = @intCast(u8, result_line_bytes / width);
            std.debug.assert(pixel_stride == dest_format.getPixelStride());

            var process_row_data = RowProcessData{
                .dest_row = undefined,
                .src_format = header.getPixelFormat(),
                .dest_format = dest_format,
                .header = header,
                .temp_allocator = options.temp_allocator.?,
            };

            var i: u32 = 0;
            while (i < height) : (i += 1) {
                var filled = decompressStream.read(current_row[filter_stride - 1 ..]) catch return error.InvalidData;
                if (filled != line_bytes + 1) return error.EndOfStream;
                try defilter(current_row, prev_row, filter_stride);
                current_row[filter_stride - 1] = 0; // zero out the filter byte

                process_row_data.dest_row = dest[0..result_line_bytes];
                dest = dest[result_line_bytes..];

                spreadRowData(process_row_data.dest_row, current_row, header, filter_stride, pixel_stride);

                var result_format = try processRow(options.processors, &process_row_data);
                if (result_format != dest_format) return error.InvalidData;

                var tmp = prev_row;
                prev_row = current_row;
                current_row = tmp;
            }

            return result;
        }

        fn processPalette(options: *const ReaderOptions, palette: []color.Colorf32) ImageParsingError!void {
            var process_data = PaletteProcessData{ .palette = palette, .temp_allocator = options.temp_allocator.? };
            for (options.processors) |*processor| {
                try processor.processPalette(&process_data);
            }
        }

        fn defilter(current_row: []u8, prev_row: []u8, filter_stride: u8) ImageParsingError!void {
            const filter_byte = current_row[filter_stride - 1];
            if (filter_byte > @enumToInt(png.FilterType.paeth)) return error.InvalidData;
            const filter = @intToEnum(png.FilterType, filter_byte);
            current_row[filter_stride - 1] = 0;

            var x: u32 = filter_stride;
            switch (filter) {
                .none => {},
                .sub => while (x < current_row.len) : (x += 1) {
                    current_row[x] += current_row[x - filter_stride];
                },
                .up => while (x < current_row.len) : (x += 1) {
                    current_row[x] += prev_row[x];
                },
                .average => while (x < current_row.len) : (x += 1) {
                    current_row[x] += (current_row[x - filter_stride] + prev_row[x]) / 2;
                },
                .paeth => while (x < current_row.len) : (x += 1) {
                    const a = current_row[x - filter_stride];
                    const b = prev_row[x];
                    const c = prev_row[x - filter_stride];
                    var pa: i32 = b - c;
                    var pb: i32 = a - c;
                    var pc: i32 = pa + pb;
                    if (pa < 0) pa = -pa;
                    if (pb < 0) pb = -pb;
                    if (pc < 0) pc = -pc;
                    // zig fmt: off
                    current_row[x] += if (pa <= pb and pa <= pc) @truncate(u8, a)
                                     else if (pb <= pc) @truncate(u8, b)
                                     else @truncate(u8, c);
                    // zig fmt: on
                },
            }
        }

        fn spreadRowData(
            dest_row: []u8,
            current_row: []u8,
            header: *const png.HeaderData,
            filter_stride: u8,
            pixel_stride: u8,
        ) void {
            var pix: u32 = 0;
            var src_pix: u32 = filter_stride;
            const result_line_bytes = dest_row.len;
            const channel_count = header.channelCount();
            switch (header.bit_depth) {
                1, 2, 4 => {
                    while (pix < result_line_bytes) {
                        // color_type must be Grayscale or Indexed
                        var shift = @intCast(i4, 8 - header.bit_depth);
                        var mask = @as(u8, 0xff) << @intCast(u3, shift);
                        while (shift >= 0 and pix < result_line_bytes) : (shift -= @intCast(i4, header.bit_depth)) {
                            dest_row[pix] = (current_row[src_pix] & mask) >> @intCast(u3, shift);
                            pix += pixel_stride;
                            mask >>= @intCast(u3, header.bit_depth);
                        }
                        src_pix += 1;
                    }
                },
                8 => {
                    while (pix < result_line_bytes) : (pix += pixel_stride) {
                        var c: u32 = 0;
                        while (c < channel_count) : (c += 1) {
                            dest_row[pix + c] = current_row[src_pix + c];
                        }
                        src_pix += channel_count;
                    }
                },
                16 => {
                    var current_row16 = mem.bytesAsSlice(u16, current_row);
                    var dest_row16 = mem.bytesAsSlice(u16, dest_row);
                    const pixel_stride16 = pixel_stride / 2;
                    src_pix /= 2;
                    while (pix < dest_row16.len) : (pix += pixel_stride16) {
                        var c: u32 = 0;
                        while (c < channel_count) : (c += 1) {
                            dest_row16[pix + c] = current_row16[src_pix + c];
                        }
                        src_pix += channel_count;
                    }
                },
                else => unreachable,
            }
        }

        fn processRow(processors: []ReaderProcessor, process_data: *RowProcessData) ImageParsingError!PixelFormat {
            var result_format = process_data.src_format;
            for (processors) |*processor| {
                result_format = try processor.processDataRow(process_data);
                process_data.src_format = result_format;
            }
            return result_format;
        }
    };
}

pub const ChunkProcessData = struct {
    raw_reader: imgio.ImageReader,
    chunk_length: u32,
    current_format: PixelFormat,
    header: *const png.HeaderData,
    temp_allocator: Allocator,
};

pub const PaletteProcessData = struct {
    palette: []color.Colorf32,
    temp_allocator: Allocator,
};

pub const RowProcessData = struct {
    dest_row: []u8,
    src_format: PixelFormat,
    dest_format: PixelFormat,
    header: *const png.HeaderData,
    temp_allocator: Allocator,
};

pub const ReaderProcessor = struct {
    id: u32,
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        chunk_processor: ?fn (context: *anyopaque, data: *ChunkProcessData) ImageParsingError!PixelFormat,
        palette_processor: ?fn (context: *anyopaque, data: *PaletteProcessData) ImageParsingError!void,
        data_row_processor: ?fn (context: *anyopaque, data: *RowProcessData) ImageParsingError!PixelFormat,
    };

    const Self = @This();

    pub inline fn processChunk(self: *Self, data: *ChunkProcessData) ImageParsingError!PixelFormat {
        return if (self.vtable.chunk_processor) |cp| cp(self.context, data) else data.current_format;
    }

    pub inline fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        if (self.vtable.palette_processor) |pp| try pp(self.context, data);
    }

    pub inline fn processDataRow(self: *Self, data: *RowProcessData) ImageParsingError!PixelFormat {
        return if (self.vtable.data_row_processor) |drp| drp(self.context, data) else data.dest_format;
    }

    pub fn init(
        id: *const [4]u8,
        context: anytype,
        comptime chunkProcessorFn: ?fn (ptr: @TypeOf(context), data: *ChunkProcessData) ImageParsingError!PixelFormat,
        comptime paletteProcessorFn: ?fn (ptr: @TypeOf(context), data: *PaletteProcessData) ImageParsingError!void,
        comptime dataRowProcessorFn: ?fn (ptr: @TypeOf(context), data: *RowProcessData) ImageParsingError!PixelFormat,
    ) Self {
        const Ptr = @TypeOf(context);
        const ptr_info = @typeInfo(Ptr);

        std.debug.assert(ptr_info == .Pointer); // Must be a pointer
        std.debug.assert(ptr_info.Pointer.size == .One); // Must be a single-item pointer

        const alignment = ptr_info.Pointer.alignment;

        const gen = struct {
            fn chunkProcessor(ptr: *anyopaque, data: *ChunkProcessData) ImageParsingError!PixelFormat {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                return @call(.{ .modifier = .always_inline }, chunkProcessorFn.?, .{ self, data });
            }
            fn paletteProcessor(ptr: *anyopaque, data: *PaletteProcessData) ImageParsingError!void {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                return @call(.{ .modifier = .always_inline }, paletteProcessorFn.?, .{ self, data });
            }
            fn dataRowProcessor(ptr: *anyopaque, data: *RowProcessData) ImageParsingError!PixelFormat {
                const self = @ptrCast(Ptr, @alignCast(alignment, ptr));
                return @call(.{ .modifier = .always_inline }, dataRowProcessorFn.?, .{ self, data });
            }

            const vtable = VTable{
                .chunk_processor = if (chunkProcessorFn == null) null else chunkProcessor,
                .palette_processor = if (paletteProcessorFn == null) null else paletteProcessor,
                .data_row_processor = if (dataRowProcessorFn == null) null else dataRowProcessor,
            };
        };

        return .{
            .id = std.mem.bytesToValue(u32, id),
            .context = context,
            .vtable = &gen.vtable,
        };
    }
};

pub const TrnsProcessor = struct {
    const Self = @This();
    const TRNSData = union(enum) { unset: u0, gray: u16, rgb: color.Rgb48, index_alpha: []u8 };

    trns_data: TRNSData = .{ .unset = 0 },
    processed: bool = false,

    pub fn processor(self: *Self) ReaderProcessor {
        return ReaderProcessor.init(
            "tRNS",
            self,
            processChunk,
            processPalette,
            processDataRow,
        );
    }

    pub fn processChunk(self: *Self, data: *ChunkProcessData) ImageParsingError!PixelFormat {
        // We will allow multiple tRNS chunks and load the last one
        // We ignore if we encounter this chunk with color_type that already has alpha
        var result_format = data.current_format;
        if (self.processed) {
            _ = try data.raw_reader.readNoAlloc(data.chunk_length + @sizeOf(u32)); // Skip invalid
            return result_format;
        }
        switch (data.header.color_type) {
            .grayscale => {
                if (data.chunk_length == 2 and result_format.isJustGrayscale()) {
                    self.trns_data = .{ .gray = try data.raw_reader.readIntBig(u16) };
                    result_format = if (data.header.bit_depth == 16) .grayscale16Alpha else .grayscale8Alpha;
                } else {
                    _ = try data.raw_reader.readNoAlloc(data.chunk_length); // Skip invalid
                }
            },
            .indexed => {
                if (data.chunk_length <= data.header.maxPaletteSize() and result_format.isIndex()) {
                    self.trns_data = .{ .index_alpha = try data.temp_allocator.alloc(u8, data.chunk_length) };
                    var filled = try data.raw_reader.read(self.trns_data.index_alpha);
                    if (filled != self.trns_data.index_alpha.len) return error.EndOfStream;
                } else {
                    _ = try data.raw_reader.readNoAlloc(data.chunk_length); // Skip invalid
                }
            },
            .rgb_color => {
                if (data.chunk_length == @sizeOf(color.Rgb48) and result_format.isStandardRgb()) {
                    self.trns_data = .{ .rgb = (try data.raw_reader.readStruct(color.Rgb48)).* };
                    result_format = if (data.header.bit_depth == 16) .rgba64 else .rgba32;
                } else {
                    _ = try data.raw_reader.readNoAlloc(data.chunk_length); // Skip invalid
                }
            },
            else => _ = try data.raw_reader.readNoAlloc(data.chunk_length), // Skip invalid
        }
        // Read but ignore Crc since this is not critical chunk
        _ = try data.raw_reader.readNoAlloc(@sizeOf(u32));
        return result_format;
    }

    pub fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        self.processed = true;
        switch (self.trns_data) {
            .index_alpha => |index_alpha| {
                for (index_alpha) |alpha, i| {
                    data.palette[i].a = color.toF32Color(alpha);
                }
            },
            else => unreachable,
        }
    }

    pub fn processDataRow(self: *Self, data: *RowProcessData) ImageParsingError!PixelFormat {
        self.processed = true;
        if (data.src_format.isIndex() or self.trns_data == .unset) return data.src_format;
        var pixel_stride: u8 = switch (data.dest_format) {
            .grayscale8Alpha, .grayscale16Alpha => 2,
            .rgba32, .bgra32 => 4,
            .rgba64 => 8,
            else => return data.src_format,
        };
        var pixel_pos: u32 = 0;
        switch (self.trns_data) {
            .gray => |gray_alpha| {
                switch (data.src_format) {
                    .grayscale1, .grayscale2, .grayscale4, .grayscale8 => {
                        while (pixel_pos + 1 < data.dest_row.len) : (pixel_pos += pixel_stride) {
                            data.dest_row[pixel_pos + 1] = (data.dest_row[pixel_pos] ^ @truncate(u8, gray_alpha)) *| 255;
                        }
                        return .grayscale8Alpha;
                    },
                    .grayscale16 => {
                        var dest = std.mem.bytesAsSlice(u16, data.dest_row);
                        while (pixel_pos + 1 < dest.len) : (pixel_pos += pixel_stride) {
                            dest[pixel_pos + 1] = (data.dest_row[pixel_pos] ^ gray_alpha) *| 65535;
                        }
                        return .grayscale16Alpha;
                    },
                    else => unreachable,
                }
            },
            .rgb => |tr_color| {
                switch (data.src_format) {
                    .rgb24 => {
                        var dest = std.mem.bytesAsSlice(color.Rgba32, data.dest_row);
                        pixel_stride /= 4;
                        while (pixel_pos < dest.len) : (pixel_pos += pixel_stride) {
                            var val = dest[pixel_pos];
                            val.a = if (val.r == tr_color.r and val.g == tr_color.g and val.b == tr_color.b) 0 else 255;
                            dest[pixel_pos] = val;
                        }
                        return .rgba32;
                    },
                    .rgb48 => {
                        var dest = std.mem.bytesAsSlice(color.Rgba64, data.dest_row);
                        pixel_stride = 1;
                        while (pixel_pos < dest.len) : (pixel_pos += pixel_stride) {
                            var val = dest[pixel_pos];
                            val.a = if (val.r == tr_color.r and val.g == tr_color.g and val.b == tr_color.b) 0 else 65535;
                            dest[pixel_pos] = val;
                        }
                        return .rgba64;
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }
        return data.src_format;
    }
};

pub const ReaderOptions = struct {
    /// Allocator for temporary allocations. Max 500KiB will be allocated from it.
    /// If not provided Reader will use stack memory. Some temp allocations depend
    /// on image size so they will use the main allocator since we can't guarantee
    /// they are bounded. They will be allocated after the destination image to
    /// reduce memory fragmentation and freed internally.
    temp_allocator: ?Allocator = null,

    // We need default to be no processors so they are not even compiled in if not used
    // and we need to instantiate them only if they are used.
    processors: []ReaderProcessor = &[_]ReaderProcessor{},
};

var no_processors_array = [_]ReaderProcessor{.{ .id = 0, .context = undefined, .vtable = undefined }};
pub var no_processors = no_processors_array[0..];

// ********************* TESTS *********************

const expectError = std.testing.expectError;

const valid_header_buf = png.magic_header ++ "\x00\x00\x00\x0d" ++ png.HeaderData.chunk_type ++
    "\x00\x00\x00\xff\x00\x00\x00\x75\x08\x06\x00\x00\x01\xd7\xc0\x29\x6f";

test "testDefilter" {
    var buffer = [_]u8{ 0, 1, 2, 3, 0, 5, 6, 7 };
    // Start with none filter
    var current_row: []u8 = buffer[4..];
    var prev_row: []u8 = buffer[0..4];
    var filter_stride: u8 = 1;

    try testFilter(png.FilterType.none, current_row, prev_row, filter_stride, &[_]u8{ 0, 5, 6, 7 });
    try testFilter(png.FilterType.sub, current_row, prev_row, filter_stride, &[_]u8{ 0, 5, 11, 18 });
    try testFilter(png.FilterType.up, current_row, prev_row, filter_stride, &[_]u8{ 0, 6, 13, 21 });
    try testFilter(png.FilterType.average, current_row, prev_row, filter_stride, &[_]u8{ 0, 6, 17, 31 });
    try testFilter(png.FilterType.paeth, current_row, prev_row, filter_stride, &[_]u8{ 0, 7, 24, 55 });

    var buffer16 = [_]u8{ 0, 0, 1, 2, 3, 4, 5, 6, 7, 0, 0, 8, 9, 10, 11, 12, 13, 14 };
    current_row = buffer16[9..];
    prev_row = buffer16[0..9];
    filter_stride = 2;

    try testFilter(png.FilterType.none, current_row, prev_row, filter_stride, &[_]u8{ 0, 0, 8, 9, 10, 11, 12, 13, 14 });
    try testFilter(png.FilterType.sub, current_row, prev_row, filter_stride, &[_]u8{ 0, 0, 8, 9, 18, 20, 30, 33, 44 });
    try testFilter(png.FilterType.up, current_row, prev_row, filter_stride, &[_]u8{ 0, 0, 9, 11, 21, 24, 35, 39, 51 });
    try testFilter(png.FilterType.average, current_row, prev_row, filter_stride, &[_]u8{ 0, 0, 9, 12, 27, 32, 51, 58, 80 });
    try testFilter(png.FilterType.paeth, current_row, prev_row, filter_stride, &[_]u8{ 0, 0, 10, 14, 37, 46, 88, 104, 168 });
}

fn testFilter(filter_type: png.FilterType, current_row: []u8, prev_row: []u8, filter_stride: u8, expected: []const u8) !void {
    const expectEqualSlices = std.testing.expectEqualSlices;
    current_row[filter_stride - 1] = @enumToInt(filter_type);
    try BufferReader.defilter(current_row, prev_row, filter_stride);
    try expectEqualSlices(u8, expected, current_row);
}

test "spreadRowData" {
    var header: png.HeaderData = undefined;
    header.color_type = png.ColorType.grayscale;
    header.bit_depth = 1;
    // 16 destination bytes, filter byte and two more bytes of current_row
    var dest_buffer = [_]u8{0} ** 32;
    var cur_buffer = [_]u8{ 0, 0, 0, 0, 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 };
    var dest_row: []u8 = dest_buffer[0..16];
    var current_row: []u8 = cur_buffer[3..6];
    var filter_stride: u8 = 1;
    var pixel_stride: u8 = 1;
    const expectEqualSlices = std.testing.expectEqualSlices;

    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0 }, dest_row);
    dest_row = dest_buffer[0..32];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0 }, dest_row);

    header.bit_depth = 2;
    pixel_stride = 1;
    dest_row = dest_buffer[0..8];
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 2, 2, 1, 1, 1, 3, 3, 0 }, dest_row);
    dest_row = dest_buffer[0..16];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 2, 0, 2, 0, 1, 0, 1, 0, 1, 0, 3, 0, 3, 0, 0, 0 }, dest_row);

    header.bit_depth = 4;
    pixel_stride = 1;
    dest_row = dest_buffer[0..4];
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa, 0x5, 0x7, 0xc }, dest_row);
    dest_row = dest_buffer[0..8];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa, 0, 0x5, 0, 0x7, 0, 0xc, 0 }, dest_row);

    header.bit_depth = 8;
    pixel_stride = 1;
    dest_row = dest_buffer[0..2];
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c }, dest_row);
    dest_row = dest_buffer[0..4];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0, 0x7c, 0 }, dest_row);

    header.color_type = png.ColorType.grayscale_alpha;
    header.bit_depth = 8;
    current_row = cur_buffer[2..8];
    dest_row = dest_buffer[0..4];
    filter_stride = 2;
    pixel_stride = 2;
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0xf2 }, dest_row);
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0, 0, 0x39, 0xf2, 0, 0 }, dest_row);

    header.color_type = png.ColorType.grayscale_alpha;
    header.bit_depth = 16;
    current_row = cur_buffer[0..12];
    dest_row = dest_buffer[0..8];
    filter_stride = 4;
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 }, dest_row);

    header.color_type = png.ColorType.rgb_color;
    header.bit_depth = 8;
    current_row = cur_buffer[1..10];
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    filter_stride = 3;
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0, 0xf2, 0x5b, 0x15, 0 }, dest_row);

    header.color_type = png.ColorType.rgba_color;
    header.bit_depth = 16;
    var cbuffer16 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 };
    current_row = cbuffer16[0..];
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    filter_stride = 8;
    pixel_stride = 8;
    BufferReader.spreadRowData(dest_row, current_row, &header, filter_stride, pixel_stride);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 }, dest_row);
}

test "loadHeader_valid" {
    const expectEqual = std.testing.expectEqual;
    var reader = fromMemory(valid_header_buf[0..]);
    var header = try reader.loadHeader();
    try expectEqual(@as(u32, 0xff), header.width());
    try expectEqual(@as(u32, 0x75), header.height());
    try expectEqual(@as(u8, 8), header.bit_depth);
    try expectEqual(png.ColorType.rgba_color, header.color_type);
    try expectEqual(png.CompressionMethod.deflate, header.compression_method);
    try expectEqual(png.FilterMethod.adaptive, header.filter_method);
    try expectEqual(png.InterlaceMethod.adam7, header.interlace_method);
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
    const buf = png.magic_header ++ "\x00\x00\x01\x0d" ++ png.HeaderData.chunk_type ++ "asad";
    var reader = fromMemory(buf[0..]);
    try expectError(error.InvalidData, reader.loadHeader());
}

test "loadHeader_shortHeader" {
    const buf = png.magic_header ++ "\x00\x00\x00\x0d" ++ png.HeaderData.chunk_type ++ "asad";
    var reader = fromMemory(buf[0..]);
    try expectError(error.EndOfStream, reader.loadHeader());
}

test "loadHeader_invalidHeaderData" {
    var buf: [valid_header_buf.len]u8 = undefined;
    std.mem.copy(u8, buf[0..], valid_header_buf[0..]);
    var pos = png.magic_header.len + @sizeOf(png.ChunkHeader);

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
