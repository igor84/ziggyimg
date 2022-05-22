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

const ProfData = struct {
    name: []const u8 = &[_]u8{},
    count: u32 = 0,
    dur: u64 = 0,
};
var prof_data_list = [_]ProfData{.{}} ** 113;

// To measure some function just add these two lines to its start:
// var timer = std.time.Timer.start() catch unreachable;
// defer measure(@src().fn_name, timer.read());
fn measure(comptime name: []const u8, dur: u64) void {
    const index = Crc32.hash(name) % prof_data_list.len;
    if (prof_data_list[index].name.len > 0 and prof_data_list[index].name[0] != name[0]) return;
    prof_data_list[index].name = name;
    prof_data_list[index].count += 1;
    prof_data_list[index].dur += dur;
}

pub fn printProfData() void {
    for (prof_data_list) |prof_data| {
        if (prof_data.count == 0) continue;
        std.debug.print("{s} => x{} {s}\n", .{ prof_data.name, prof_data.count, std.fmt.fmtDuration(prof_data.dur) });
    }
}

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
            const l = id & 0xff;
            // Critical chunks are already processed but we can still notify any number of processors about them
            var processed = l >= 'A' and l <= 'Z';
            for (processors) |*processor| {
                if (processor.id == id) {
                    const new_format = try processor.processChunk(chunk_process_data);
                    std.debug.assert(new_format.pixelStride() >= chunk_process_data.current_format.pixelStride());
                    chunk_process_data.current_format = new_format;
                    if (!processed) {
                        // For non critical chunks we only allow one processor so we break after the first one
                        processed = true;
                        break;
                    }
                }
            }

            // If noone loaded this chunk we need to skip over it
            if (!processed) {
                _ = try chunk_process_data.raw_reader.seekBy(@intCast(i64, chunk_process_data.chunk_length + 4));
            }
        }
    };

    // Provides reader interface for Zlib stream that knows to read consecutive IDAT chunks.
    const IDatChunksReader = struct {
        raw_reader: *RawReader,
        processors: []ReaderProcessor,
        chunk_process_data: *ChunkProcessData,
        remaining_chunk_length: u32,
        crc: Crc32,

        const Self = @This();

        fn init(
            reader: *RawReader,
            processors: []ReaderProcessor,
            chunk_process_data: *ChunkProcessData,
        ) Self {
            var crc = Crc32.init();
            crc.update("IDAT");
            return .{
                .raw_reader = reader,
                .processors = processors,
                .chunk_process_data = chunk_process_data,
                .remaining_chunk_length = chunk_process_data.chunk_length,
                .crc = crc,
            };
        }

        fn read(self: *Self, dest: []u8) ImageParsingError!usize {
            if (self.remaining_chunk_length == 0) return 0;
            const new_dest = dest;

            var to_read = new_dest.len;
            if (to_read > self.remaining_chunk_length) to_read = self.remaining_chunk_length;
            const read_count = try self.raw_reader.read(new_dest[0..to_read]);
            self.remaining_chunk_length -= @intCast(u32, read_count);
            self.crc.update(new_dest[0..read_count]);

            if (self.remaining_chunk_length == 0) {
                // First read and check CRC of just finished chunk
                const expected_crc = try self.raw_reader.readIntBig(u32);
                if (self.crc.final() != expected_crc) return error.InvalidData;

                try Common.processChunk(self.processors, png.HeaderData.chunk_type_id, self.chunk_process_data);

                self.crc = Crc32.init();
                self.crc.update("IDAT");

                // Try to load the next IDAT chunk
                const chunk = try self.raw_reader.readStruct(png.ChunkHeader);
                if (chunk.type == std.mem.bytesToValue(u32, "IDAT")) {
                    self.remaining_chunk_length = chunk.length();
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
            const sig = try self.raw_reader.readNoAlloc(png.magic_header.len);
            if (!mem.eql(u8, sig[0..], png.magic_header)) return error.InvalidData;

            const chunk = try self.raw_reader.readStruct(png.ChunkHeader);
            if (chunk.type != png.HeaderData.chunk_type_id) return error.InvalidData;
            if (chunk.length() != @sizeOf(png.HeaderData)) return error.InvalidData;

            const header = (try self.raw_reader.readStruct(png.HeaderData));
            if (!header.isValid()) return error.InvalidData;

            const expected_crc = try self.raw_reader.readIntBig(u32);
            var crc = Crc32.init();
            crc.update(png.HeaderData.chunk_type);
            crc.update(mem.asBytes(header));
            const actual_crc = crc.final();
            if (expected_crc != actual_crc) return error.InvalidData;

            return header.*;
        }

        /// Loads the png image using the given allocator and options.
        /// The options allow you to pass in a custom allocator for temporary allocations.
        /// By default it will use a fixed buffer on stack for temporary allocations.
        /// You can also pass in an array of chunk processors. You can use def_processors
        /// array if you want to use these default set of processors:
        /// 1. tRNS processor that decodes the tRNS chunk if it exists into an alpha channel
        /// 2. PLTE processor that decodes the indexed image with a palette into a RGB image.
        /// If you want default processors with default temp allocator you can just pass
        /// predefined def_options. If you just pass .{} no processors will be used.
        pub fn load(self: *Self, allocator: Allocator, options: ReaderOptions) ImageParsingError!PixelStorage {
            const header = try self.loadHeader();
            return try self.loadWithHeader(&header, allocator, options);
        }

        /// Loads the png image for which the header has already been loaded.
        /// For options param description look at the load method docs.
        pub fn loadWithHeader(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: ReaderOptions,
        ) ImageParsingError!PixelStorage {
            var opts = options;
            var tmp_allocator = options.temp_allocator;
            var fb_allocator = std.heap.FixedBufferAllocator.init(try tmp_allocator.alloc(u8, required_temp_bytes));
            defer tmp_allocator.free(fb_allocator.buffer);
            opts.temp_allocator = fb_allocator.allocator();
            return try doLoad(self, header, allocator, &opts);
        }

        fn asU32(str: *const [4:0]u8) u32 {
            return std.mem.bytesToValue(u32, str);
        }

        fn doLoad(
            self: *Self,
            header: *const png.HeaderData,
            allocator: Allocator,
            options: *const ReaderOptions,
        ) ImageParsingError!PixelStorage {
            var palette: []color.Rgb24 = &[_]color.Rgb24{};
            var data_found = false;
            var result: PixelStorage = undefined;

            var chunk_process_data = ChunkProcessData{
                .raw_reader = ImageReader.wrap(&self.raw_reader),
                .chunk_length = @sizeOf(png.HeaderData),
                .current_format = header.getPixelFormat(),
                .header = header,
                .temp_allocator = options.temp_allocator,
            };
            try Common.processChunk(options.processors, png.HeaderData.chunk_type_id, &chunk_process_data);

            while (true) {
                const chunk = try self.raw_reader.readStruct(png.ChunkHeader);

                switch (chunk.type) {
                    asU32("IHDR") => {
                        return error.InvalidData; // We already processed IHDR so another one is an error
                    },
                    asU32("IEND") => {
                        if (!data_found) return error.InvalidData;
                        _ = try self.raw_reader.readInt(u32); // Read and ignore the crc
                        chunk_process_data.chunk_length = chunk.length();
                        try Common.processChunk(options.processors, chunk.type, &chunk_process_data);
                        return result;
                    },
                    asU32("IDAT") => {
                        if (data_found) return error.InvalidData;
                        if (header.color_type == .indexed and palette.len == 0) return error.InvalidData;
                        chunk_process_data.chunk_length = chunk.length();
                        result = try self.readAllData(header, palette, allocator, options, &chunk_process_data);
                        data_found = true;
                    },
                    asU32("PLTE") => {
                        if (!header.allowsPalette()) return error.InvalidData;
                        if (palette.len > 0) return error.InvalidData;
                        // We ignore if tRNS is already found
                        const chunk_length = chunk.length();
                        if (chunk_length % 3 != 0) return error.InvalidData;
                        const length = chunk_length / 3;
                        if (length > header.maxPaletteSize()) return error.InvalidData;
                        if (data_found) {
                            // If IDAT was already processed we skip and ignore this palette
                            _ = try self.raw_reader.seekBy(chunk_length + @sizeOf(u32));
                        } else {
                            if (!is_from_file) {
                                const palette_bytes = try self.raw_reader.readNoAlloc(chunk_length);
                                palette = std.mem.bytesAsSlice(png.PaletteType, palette_bytes);
                            } else {
                                palette = try options.temp_allocator.alloc(color.Rgb24, length);
                                const filled = try self.raw_reader.read(mem.sliceAsBytes(palette));
                                if (filled != palette.len * @sizeOf(color.Rgb24)) return error.EndOfStream;
                            }

                            const expected_crc = try self.raw_reader.readIntBig(u32);
                            var crc = Crc32.init();
                            crc.update("PLTE");
                            crc.update(mem.sliceAsBytes(palette));
                            const actual_crc = crc.final();
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
            const native_endian = comptime @import("builtin").cpu.arch.endian();
            const is_little_endian = native_endian == .Little;
            const width = header.width();
            const height = header.height();
            const channel_count = header.channelCount();
            const dest_format = chunk_process_data.current_format;
            var result = try PixelStorage.init(allocator, dest_format, width * height);
            errdefer result.deinit(allocator);
            var idat_chunks_reader = IDatChunksReader.init(&self.raw_reader, options.processors, chunk_process_data);
            var idat_reader: IDATReader = .{ .context = &idat_chunks_reader };
            var decompressStream = std.compress.zlib.zlibStream(options.temp_allocator, idat_reader) catch return error.InvalidData;

            if (palette.len > 0) {
                var dest_palette = if (result.getPallete()) |res_palette|
                    res_palette
                else
                    try options.temp_allocator.alloc(color.Rgba32, palette.len);
                for (palette) |entry, n| {
                    dest_palette[n] = entry.toRgba32();
                }
                try processPalette(options, dest_palette);
            }

            var dest = result.pixelsAsBytes();

            // For defiltering we need to keep two rows in memory so we allocate space for that
            const filter_stride = (header.bit_depth + 7) / 8 * channel_count; // 1 to 8 bytes
            const line_bytes = header.lineBytes();
            const virtual_line_bytes = line_bytes + filter_stride;
            const result_line_bytes = @intCast(u32, dest.len / height);
            var tmpbytes = 2 * virtual_line_bytes;
            // For deinterlacing we also need one temporary row of resulting pixels
            if (header.interlace_method == .adam7) tmpbytes += result_line_bytes;
            var tmp_allocator = if (tmpbytes < 128 * 1024) options.temp_allocator else allocator;
            var tmp_buffer = try tmp_allocator.alloc(u8, tmpbytes);
            defer tmp_allocator.free(tmp_buffer);
            mem.set(u8, tmp_buffer, 0);
            var prev_row = tmp_buffer[0..virtual_line_bytes];
            var current_row = tmp_buffer[virtual_line_bytes .. 2 * virtual_line_bytes];
            const pixel_stride = @intCast(u8, result_line_bytes / width);
            std.debug.assert(pixel_stride == dest_format.pixelStride());

            var process_row_data = RowProcessData{
                .dest_row = undefined,
                .src_format = header.getPixelFormat(),
                .dest_format = dest_format,
                .header = header,
                .temp_allocator = options.temp_allocator,
            };

            if (header.interlace_method == .none) {
                var i: u32 = 0;
                while (i < height) : (i += 1) {
                    var loaded = decompressStream.read(current_row[filter_stride - 1 ..]) catch return error.InvalidData;
                    var filled = loaded;
                    while (loaded > 0 and filled != line_bytes + 1) {
                        loaded = decompressStream.read(current_row[filter_stride - 1 + filled ..]) catch return error.InvalidData;
                        filled += loaded;
                    }
                    if (filled != line_bytes + 1) return error.EndOfStream;
                    try defilter(current_row, prev_row, filter_stride);

                    process_row_data.dest_row = dest[0..result_line_bytes];
                    dest = dest[result_line_bytes..];

                    spreadRowData(
                        process_row_data.dest_row,
                        current_row[filter_stride..],
                        header.bit_depth,
                        channel_count,
                        pixel_stride,
                        is_little_endian,
                    );

                    const result_format = try processRow(options.processors, &process_row_data);
                    if (result_format != dest_format) return error.InvalidData;

                    const tmp = prev_row;
                    prev_row = current_row;
                    current_row = tmp;
                }
            } else {
                const start_x = [7]u8{ 0, 4, 0, 2, 0, 1, 0 };
                const start_y = [7]u8{ 0, 0, 4, 0, 2, 0, 1 };
                const xinc = [7]u8{ 8, 8, 4, 4, 2, 2, 1 };
                const yinc = [7]u8{ 8, 8, 8, 4, 4, 2, 2 };
                const pass_width = [7]u32{
                    (width + 7) / 8,
                    (width + 3) / 8,
                    (width + 3) / 4,
                    (width + 1) / 4,
                    (width + 1) / 2,
                    width / 2,
                    width,
                };
                const pass_height = [7]u32{
                    (height + 7) / 8,
                    (height + 7) / 8,
                    (height + 3) / 8,
                    (height + 3) / 4,
                    (height + 1) / 4,
                    (height + 1) / 2,
                    height / 2,
                };
                const pixel_bits = header.pixelBits();
                const deinterlace_bit_depth: u8 = if (header.bit_depth <= 8) 8 else 16;
                var dest_row = tmp_buffer[virtual_line_bytes * 2 ..];

                var pass: u32 = 0;
                while (pass < 7) : (pass += 1) {
                    if (pass_width[pass] == 0 or pass_height[pass] == 0) continue;
                    const pass_bytes = (pixel_bits * pass_width[pass] + 7) / 8;
                    const pass_length = pass_bytes + filter_stride;
                    const result_pass_line_bytes = pixel_stride * pass_width[pass];
                    const deinterlace_stride = xinc[pass] * pixel_stride;
                    mem.set(u8, prev_row, 0);
                    const destx = start_x[pass] * pixel_stride;
                    var desty = start_y[pass];
                    var y: u32 = 0;
                    while (y < pass_height[pass]) : (y += 1) {
                        var loaded = decompressStream.read(current_row[filter_stride - 1 .. pass_length]) catch return error.InvalidData;
                        var filled = loaded;
                        while (loaded > 0 and filled != pass_bytes + 1) {
                            loaded = decompressStream.read(current_row[filter_stride - 1 + filled ..]) catch return error.InvalidData;
                            filled += loaded;
                        }
                        if (filled != pass_bytes + 1) return error.EndOfStream;
                        try defilter(current_row[0..pass_length], prev_row[0..pass_length], filter_stride);

                        process_row_data.dest_row = dest_row[0..result_pass_line_bytes];

                        spreadRowData(
                            process_row_data.dest_row,
                            current_row[filter_stride..],
                            header.bit_depth,
                            channel_count,
                            pixel_stride,
                            false,
                        );

                        const result_format = try processRow(options.processors, &process_row_data);
                        if (result_format != dest_format) return error.InvalidData;

                        const line_start_adr = desty * result_line_bytes;
                        const start_byte = line_start_adr + destx;
                        const end_byte = line_start_adr + result_line_bytes;
                        spreadRowData(
                            dest[start_byte..end_byte],
                            process_row_data.dest_row,
                            deinterlace_bit_depth,
                            result_format.channelCount(),
                            deinterlace_stride,
                            is_little_endian,
                        );

                        desty += yinc[pass];

                        const tmp = prev_row;
                        prev_row = current_row;
                        current_row = tmp;
                    }
                }
            }

            // Just make sure zip stream gets to its end
            var buf: [8]u8 = undefined;
            var shouldBeZero = decompressStream.read(buf[0..]) catch return error.InvalidData;

            std.debug.assert(shouldBeZero == 0);

            return result;
        }

        fn processPalette(options: *const ReaderOptions, palette: []color.Rgba32) ImageParsingError!void {
            var process_data = PaletteProcessData{ .palette = palette, .temp_allocator = options.temp_allocator };
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
                    current_row[x] +%= current_row[x - filter_stride];
                },
                .up => while (x < current_row.len) : (x += 1) {
                    current_row[x] +%= prev_row[x];
                },
                .average => while (x < current_row.len) : (x += 1) {
                    current_row[x] +%= @truncate(u8, (@intCast(u32, current_row[x - filter_stride]) + @intCast(u32, prev_row[x])) / 2);
                },
                .paeth => while (x < current_row.len) : (x += 1) {
                    const a = current_row[x - filter_stride];
                    const b = prev_row[x];
                    const c = prev_row[x - filter_stride];
                    var pa: i32 = @intCast(i32, b) - c;
                    var pb: i32 = @intCast(i32, a) - c;
                    var pc: i32 = pa + pb;
                    if (pa < 0) pa = -pa;
                    if (pb < 0) pb = -pb;
                    if (pc < 0) pc = -pc;
                    // zig fmt: off
                    current_row[x] +%= if (pa <= pb and pa <= pc) a
                                       else if (pb <= pc) b
                                       else c;
                    // zig fmt: on
                },
            }
        }

        fn spreadRowData(
            dest_row: []u8,
            current_row: []u8,
            bit_depth: u8,
            channel_count: u8,
            pixel_stride: u8,
            comptime byteswap: bool,
        ) void {
            var pix: u32 = 0;
            var src_pix: u32 = 0;
            const result_line_bytes = dest_row.len;
            switch (bit_depth) {
                1, 2, 4 => {
                    while (pix < result_line_bytes) {
                        // color_type must be Grayscale or Indexed
                        var shift = @intCast(i4, 8 - bit_depth);
                        var mask = @as(u8, 0xff) << @intCast(u3, shift);
                        while (shift >= 0 and pix < result_line_bytes) : (shift -= @intCast(i4, bit_depth)) {
                            dest_row[pix] = (current_row[src_pix] & mask) >> @intCast(u3, shift);
                            pix += pixel_stride;
                            mask >>= @intCast(u3, bit_depth);
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
                            // This is a comptime if so it is not executed in every loop
                            dest_row16[pix + c] = if (byteswap) @byteSwap(u16, current_row16[src_pix + c]) else current_row16[src_pix + c];
                        }
                        src_pix += channel_count;
                    }
                },
                else => unreachable,
            }
        }

        fn processRow(processors: []ReaderProcessor, process_data: *RowProcessData) ImageParsingError!PixelFormat {
            const starting_format = process_data.src_format;
            var result_format = starting_format;
            for (processors) |*processor| {
                result_format = try processor.processDataRow(process_data);
                process_data.src_format = result_format;
            }
            process_data.src_format = starting_format;
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
    palette: []color.Rgba32,
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
    const TRNSData = union(enum) { unset: void, gray: u16, rgb: color.Rgb48, index_alpha: []u8 };

    trns_data: TRNSData = .unset,
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
        // We will allow multiple tRNS chunks and load the first one
        // We ignore if we encounter this chunk with color_type that already has alpha
        var result_format = data.current_format;
        if (self.processed) {
            try data.raw_reader.seekBy(data.chunk_length + @sizeOf(u32)); // Skip invalid
            return result_format;
        }
        switch (result_format) {
            .grayscale1, .grayscale2, .grayscale4, .grayscale8, .grayscale16 => {
                if (data.chunk_length == 2) {
                    self.trns_data = .{ .gray = try data.raw_reader.readIntBig(u16) };
                    result_format = if (result_format == .grayscale16) .grayscale16Alpha else .grayscale8Alpha;
                } else {
                    try data.raw_reader.seekBy(data.chunk_length); // Skip invalid
                }
            },
            .index1, .index2, .index4, .index8, .index16 => {
                if (data.chunk_length <= data.header.maxPaletteSize()) {
                    self.trns_data = .{ .index_alpha = try data.temp_allocator.alloc(u8, data.chunk_length) };
                    const filled = try data.raw_reader.read(self.trns_data.index_alpha);
                    if (filled != self.trns_data.index_alpha.len) return error.EndOfStream;
                } else {
                    try data.raw_reader.seekBy(data.chunk_length); // Skip invalid
                }
            },
            .rgb24, .rgb48 => {
                if (data.chunk_length == @sizeOf(color.Rgb48)) {
                    self.trns_data = .{ .rgb = (try data.raw_reader.readStruct(color.Rgb48)).* };
                    result_format = if (result_format == .rgb48) .rgba64 else .rgba32;
                } else {
                    try data.raw_reader.seekBy(data.chunk_length); // Skip invalid
                }
            },
            else => try data.raw_reader.seekBy(data.chunk_length), // Skip invalid
        }
        // Read but ignore Crc since this is not critical chunk
        try data.raw_reader.seekBy(@sizeOf(u32));
        return result_format;
    }

    pub fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        self.processed = true;
        switch (self.trns_data) {
            .index_alpha => |index_alpha| {
                for (index_alpha) |alpha, i| {
                    data.palette[i].a = alpha;
                }
            },
            .unset => return,
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

pub const PlteProcessor = struct {
    const Self = @This();

    palette: []color.Rgba32 = undefined,
    processed: bool = false,

    pub fn processor(self: *Self) ReaderProcessor {
        return ReaderProcessor.init(
            "PLTE",
            self,
            processChunk,
            processPalette,
            processDataRow,
        );
    }

    pub fn processChunk(self: *Self, data: *ChunkProcessData) ImageParsingError!PixelFormat {
        // This is critical chunk so it is already read and there is no need to read it here
        var result_format = data.current_format;
        if (self.processed or !result_format.isIndex()) {
            self.processed = true;
            return result_format;
        }

        return .rgba32;
    }

    pub fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        self.processed = true;
        self.palette = data.palette;
    }

    pub fn processDataRow(self: *Self, data: *RowProcessData) ImageParsingError!PixelFormat {
        self.processed = true;
        if (!data.src_format.isIndex() or self.palette.len == 0) return data.src_format;
        var pixel_stride: u8 = switch (data.dest_format) {
            .rgba32, .bgra32 => 4,
            .rgba64 => 8,
            else => return data.src_format,
        };

        var pixel_pos: u32 = 0;
        switch (data.src_format) {
            .index1, .index2, .index4, .index8 => {
                while (pixel_pos + 3 < data.dest_row.len) : (pixel_pos += pixel_stride) {
                    const index = data.dest_row[pixel_pos];
                    const entry = self.palette[index];
                    data.dest_row[pixel_pos] = entry.r;
                    data.dest_row[pixel_pos + 1] = entry.g;
                    data.dest_row[pixel_pos + 2] = entry.b;
                    data.dest_row[pixel_pos + 3] = entry.a;
                }
            },
            .index16 => {
                while (pixel_pos + 3 < data.dest_row.len) : (pixel_pos += pixel_stride) {
                    //const index_buf: [2]u8 = .{data.dest_row[pixel_pos], data.dest_row[pixel_pos + 1]};
                    const index = std.mem.bytesToValue(u16, &[2]u8{ data.dest_row[pixel_pos], data.dest_row[pixel_pos + 1] });
                    const entry = self.palette[index];
                    data.dest_row[pixel_pos] = entry.r;
                    data.dest_row[pixel_pos + 1] = entry.g;
                    data.dest_row[pixel_pos + 2] = entry.b;
                    data.dest_row[pixel_pos + 3] = entry.a;
                }
            },
            else => unreachable,
        }

        return .rgba32;
    }
};

/// The options you need to pass to PNG reader. If you want default options
/// with buffer for temporary allocations on the stack and default set of
/// processors just use this:
/// var def_options = DefOptions{};
/// png_reader.load(main_allocator, def_options.get());
/// Note that application can define its own DefPngOptions in the root file
/// and all the code that uses DefOptions will actually use that.
pub const ReaderOptions = struct {
    /// Allocator for temporary allocations. The consant required_temp_bytes defines
    /// the maximum bytes that will be allocated from it. Some temp allocations depend
    /// on image size so they will use the main allocator since we can't guarantee
    /// they are bounded. They will be allocated after the destination image to
    /// reduce memory fragmentation and freed internally.
    temp_allocator: Allocator,

    /// Default is no processors so they are not even compiled in if not used.
    /// If you want a default set of processors create a DefProcessors object
    /// call get() on it and pass that here.
    /// Note that application can define its own DefPngProcessors and all the
    /// code that uses DefProcessors will actually use that.
    processors: []ReaderProcessor = &[_]ReaderProcessor{},

    pub fn init(temp_allocator: Allocator) ReaderOptions {
        return .{ .temp_allocator = temp_allocator };
    }

    pub fn initWithProcessors(temp_allocator: Allocator, processors: []ReaderProcessor) ReaderOptions {
        return .{ .temp_allocator = temp_allocator, .processors = processors };
    }
};

// decompressor.zig:294 claims to use up to 300KiB from provided allocator but when
// testing with huge png file it used 760KiB.
// Original zlib claims it only needs 44KiB so next task is to rewrite zig's zlib :).
pub const required_temp_bytes = 800 * 1024;

const root = @import("root");

/// Applications can override this by defining DefPngProcessors struct in their root source file.
pub const DefProcessors = if (@hasDecl(root, "DefPngProcessors"))
    root.DefPngProcessors
else
    struct {
        trns_processor: TrnsProcessor = .{},
        plte_processor: PlteProcessor = .{},
        processors_buffer: [2]ReaderProcessor = undefined,

        const Self = @This();

        pub fn get(self: *Self) []ReaderProcessor {
            self.processors_buffer[0] = self.trns_processor.processor();
            self.processors_buffer[1] = self.plte_processor.processor();
            return self.processors_buffer[0..];
        }
    };

/// Applications can override this by defining DefPngOptions struct in their root source file.
pub const DefOptions = if (@hasDecl(root, "DefPngOptions"))
    root.DefPngOptions
else
    struct {
        def_processors: DefProcessors = .{},
        tmp_buffer: [required_temp_bytes]u8 = undefined,
        fb_allocator: std.heap.FixedBufferAllocator = undefined,

        const Self = @This();

        pub fn get(self: *Self) ReaderOptions {
            self.fb_allocator = std.heap.FixedBufferAllocator.init(self.tmp_buffer[0..]);
            return .{ .temp_allocator = self.fb_allocator.allocator(), .processors = self.def_processors.get() };
        }
    };

// ********************* TESTS *********************

const expectError = std.testing.expectError;

const valid_header_buf = png.magic_header ++ "\x00\x00\x00\x0d" ++ png.HeaderData.chunk_type ++
    "\x00\x00\x00\xff\x00\x00\x00\x75\x08\x06\x00\x00\x01\xf6\x24\x07\xe2";

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
    var channel_count: u8 = 1;
    var bit_depth: u8 = 1;
    // 16 destination bytes, filter byte and two more bytes of current_row
    var dest_buffer = [_]u8{0} ** 32;
    var cur_buffer = [_]u8{ 0, 0, 0, 0, 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 };
    var dest_row: []u8 = dest_buffer[0..16];
    var current_row: []u8 = cur_buffer[3..6];
    var filter_stride: u8 = 1;
    var pixel_stride: u8 = 1;
    const expectEqualSlices = std.testing.expectEqualSlices;

    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 1, 1, 1, 1, 0, 0 }, dest_row);
    dest_row = dest_buffer[0..32];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 0 }, dest_row);

    bit_depth = 2;
    pixel_stride = 1;
    dest_row = dest_buffer[0..8];
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 2, 2, 1, 1, 1, 3, 3, 0 }, dest_row);
    dest_row = dest_buffer[0..16];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 2, 0, 2, 0, 1, 0, 1, 0, 1, 0, 3, 0, 3, 0, 0, 0 }, dest_row);

    bit_depth = 4;
    pixel_stride = 1;
    dest_row = dest_buffer[0..4];
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa, 0x5, 0x7, 0xc }, dest_row);
    dest_row = dest_buffer[0..8];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa, 0, 0x5, 0, 0x7, 0, 0xc, 0 }, dest_row);

    bit_depth = 8;
    pixel_stride = 1;
    dest_row = dest_buffer[0..2];
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c }, dest_row);
    dest_row = dest_buffer[0..4];
    pixel_stride = 2;
    std.mem.set(u8, dest_row, 0);
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0, 0x7c, 0 }, dest_row);

    channel_count = 2; // grayscale_alpha
    bit_depth = 8;
    current_row = cur_buffer[2..8];
    dest_row = dest_buffer[0..4];
    filter_stride = 2;
    pixel_stride = 2;
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0xf2 }, dest_row);
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0, 0, 0x39, 0xf2, 0, 0 }, dest_row);

    bit_depth = 16;
    current_row = cur_buffer[0..12];
    dest_row = dest_buffer[0..8];
    filter_stride = 4;
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, true);
    try expectEqualSlices(u8, &[_]u8{ 0x7c, 0xa5, 0xf2, 0x39, 0x15, 0x5b, 0xd1, 0x78 }, dest_row);

    channel_count = 3;
    bit_depth = 8;
    current_row = cur_buffer[1..10];
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    filter_stride = 3;
    pixel_stride = 4;
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, false);
    try expectEqualSlices(u8, &[_]u8{ 0xa5, 0x7c, 0x39, 0, 0xf2, 0x5b, 0x15, 0 }, dest_row);

    channel_count = 4;
    bit_depth = 16;
    var cbuffer16 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0xa5, 0x7c, 0x39, 0xf2, 0x5b, 0x15, 0x78, 0xd1 };
    current_row = cbuffer16[0..];
    dest_row = dest_buffer[0..8];
    std.mem.set(u8, dest_row, 0);
    filter_stride = 8;
    pixel_stride = 8;
    BufferReader.spreadRowData(dest_row, current_row[filter_stride..], bit_depth, channel_count, pixel_stride, true);
    try expectEqualSlices(u8, &[_]u8{ 0x7c, 0xa5, 0xf2, 0x39, 0x15, 0x5b, 0xd1, 0x78 }, dest_row);
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

test "official test suite" {
    try testWithDir("../ziggyimg-tests/fixtures/png/");
}

// Useful to quickly test performance on full dir of images
pub fn testWithDir(directory: []const u8) !void {
    var testdir = std.fs.cwd().openDir(directory, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch null;
    if (testdir) |*dir| {
        defer dir.close();
        var it = dir.iterate();
        std.debug.print("\n", .{});
        while (try it.next()) |entry| {
            if (entry.kind != .File or !std.mem.eql(u8, std.fs.path.extension(entry.name), ".png")) continue;

            std.debug.print("Testing file {s}\n", .{entry.name});
            var tst_file = try dir.openFile(entry.name, .{ .mode = .read_only });
            defer tst_file.close();
            var reader = fromFile(tst_file);
            if (entry.name[0] == 'x' and entry.name[2] != 't' and entry.name[2] != 's') {
                try std.testing.expectError(error.InvalidData, reader.loadHeader());
                continue;
            }

            var def_options = DefOptions{};
            var header = try reader.loadHeader();
            if (entry.name[0] == 'x') {
                try std.testing.expectError(error.InvalidData, reader.loadWithHeader(&header, std.testing.allocator, def_options.get()));
                continue;
            }

            var result = try reader.loadWithHeader(&header, std.testing.allocator, def_options.get());
            defer result.deinit(std.testing.allocator);
            var result_bytes = result.pixelsAsBytes();
            var md5_val = [_]u8{0} ** 16;
            std.crypto.hash.Md5.hash(result_bytes, &md5_val, .{});

            var tst_data_name: [13]u8 = undefined;
            std.mem.copy(u8, tst_data_name[0..9], entry.name[0..9]);
            std.mem.copy(u8, tst_data_name[9..12], "tsd");

            // Read test data and check with it
            if (dir.openFile(tst_data_name[0..12], .{ .mode = .read_only })) |tdata| {
                defer tdata.close();
                var treader = tdata.reader();
                var expected_md5 = [_]u8{0} ** 16;
                var read_buffer = [_]u8{0} ** 50;
                var str_format = try treader.readUntilDelimiter(read_buffer[0..], '\n');
                var expected_pixel_format = std.meta.stringToEnum(PixelFormat, str_format).?;
                var str_md5 = try treader.readUntilDelimiterOrEof(read_buffer[0..], '\n');
                _ = try std.fmt.hexToBytes(expected_md5[0..], str_md5.?);
                try std.testing.expectEqual(expected_pixel_format, std.meta.activeTag(result));
                try std.testing.expectEqualSlices(u8, expected_md5[0..], md5_val[0..]); // catch std.debug.print("MD5 Expected: {s} Got {s}\n", .{std.fmt.fmtSliceHexUpper(expected_md5[0..]), std.fmt.fmtSliceHexUpper(md5_val[0..])});
            } else |_| {
                // If there is no test data assume test is correct and write it out
                try writeTestData(dir, tst_data_name[0..12], &result, md5_val[0..]);
            }

            // Write Raw bytes
            // std.mem.copy(u8, tst_data_name[9..13], "data");
            // var rawoutput = try dir.createFile(tst_data_name[0..], .{});
            // defer rawoutput.close();
            // try rawoutput.writeAll(result_bytes);
        }
    }
}

fn writeTestData(dir: *std.fs.Dir, tst_data_name: []const u8, result: *PixelStorage, md5_val: []const u8) !void {
    var toutput = try dir.createFile(tst_data_name, .{});
    defer toutput.close();
    var writer = toutput.writer();
    try writer.print("{s}\n{s}", .{ @tagName(result.*), std.fmt.fmtSliceHexUpper(md5_val) });
}
