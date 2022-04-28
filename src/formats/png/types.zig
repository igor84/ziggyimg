const std = @import("std");
const utils = @import("../../utils.zig");
const imgio = @import("../../io.zig");
const color = @import("../../color.zig");
const PixelFormat = @import("../../pixel_format.zig").PixelFormat;
const bigToNative = std.mem.bigToNative;
const Allocator = std.mem.Allocator;
const Colorf32 = color.Colorf32;

pub const ImageParsingError = error{InvalidData} || Allocator.Error || imgio.ImageReadError;

pub const magic_header = "\x89PNG\x0D\x0A\x1A\x0A";

pub const ColorType = enum(u8) {
    grayscale = 0,
    rgb_color = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba_color = 6,

    const Self = @This();

    pub fn channelCount(self: Self) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgb_color => 3,
            .indexed => 1,
            .grayscale_alpha => 2,
            .rgba_color => 4,
        };
    }
};

pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

pub const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};

/// The compression methods supported by PNG
pub const CompressionMethod = enum(u8) { deflate = 0 };

/// The filter methods supported by PNG
pub const FilterMethod = enum(u8) { adaptive = 0 };

pub const ChunkHeader = packed struct {
    length_big_endian: u32,
    type: u32,

    const Self = @This();

    pub fn length(self: Self) u32 {
        return bigToNative(u32, self.length_big_endian);
    }
};

pub const ChunkProcessData = struct {
    raw_reader: imgio.ImageReader,
    chunk_length: u32,
    current_format: PixelFormat,
    header: *const HeaderData,
    options: *const ReaderOptions, // TODO Replace options with tmpAllocator if that is all that remains
};

pub const PaletteProcessData = struct {
    palette: []Colorf32,
};

pub const RowProcessData = struct {
    dest_row: []u8,
    src_format: PixelFormat,
    dest_format: PixelFormat,
    header: *const HeaderData,
    options: *const ReaderOptions,
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
                    self.trns_data = .{ .index_alpha = try data.options.temp_allocator.?.alloc(u8, data.chunk_length) };
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
    processors: []ReaderProcessor = def_processors[0..], // TODO: Can this be an array of pointers and should it
};

var def_trns_processor: TrnsProcessor = .{};
var def_processors = [_]ReaderProcessor{def_trns_processor.processor()};

pub const HeaderData = packed struct {
    pub const chunk_type = "IHDR";
    pub const chunk_type_id = std.mem.bytesToValue(u32, chunk_type);

    width_big_endian: u32,
    height_big_endian: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: CompressionMethod,
    filter_method: FilterMethod,
    interlace_method: InterlaceMethod,

    const Self = @This();

    pub fn width(self: *const Self) u32 {
        return bigToNative(u32, self.width_big_endian);
    }

    pub fn height(self: *const Self) u32 {
        return bigToNative(u32, self.height_big_endian);
    }

    pub fn isValid(self: *const Self) bool {
        const max_dim = std.math.maxInt(u32) >> 1;
        var w = self.width();
        var h = self.height();
        if (w == 0 or w > max_dim) return false;
        if (h == 0 or h > max_dim) return false;
        if (!utils.isEnumValid(self.color_type)) return false;
        if (!utils.isEnumValid(self.compression_method)) return false;
        if (!utils.isEnumValid(self.filter_method)) return false;
        if (!utils.isEnumValid(self.interlace_method)) return false;

        var bd = self.bit_depth;
        return switch (self.color_type) {
            .grayscale => bd == 1 or bd == 2 or bd == 4 or bd == 8 or bd == 16,
            .indexed => bd == 1 or bd == 2 or bd == 4 or bd == 8,
            else => bd == 8 or bd == 16,
        };
    }

    pub fn allowsPalette(self: *const Self) bool {
        return self.color_type == .indexed or
            self.color_type == .rgb_color or
            self.color_type == .rgba_color;
    }

    pub fn maxPaletteSize(self: *const Self) u16 {
        return if (self.bit_depth > 8) 256 else @as(u16, 1) << @truncate(u4, self.bit_depth);
    }

    pub fn channelCount(self: *const Self) u8 {
        return switch (self.color_type) {
            .grayscale => 1,
            .rgb_color => 3,
            .indexed => 1,
            .grayscale_alpha => 2,
            .rgba_color => 4,
        };
    }

    pub fn pixelBits(self: *const Self) u8 {
        return self.bit_depth * self.channelCount();
    }

    pub fn lineBytes(self: *const Self) u32 {
        return (self.pixelBits() * self.width() + 7) / 8;
    }

    pub fn getPixelFormat(self: *const Self) PixelFormat {
        return switch (self.color_type) {
            .grayscale => switch (self.bit_depth) {
                1 => PixelFormat.grayscale1,
                2 => PixelFormat.grayscale2,
                4 => PixelFormat.grayscale4,
                8 => PixelFormat.grayscale8,
                16 => PixelFormat.grayscale16,
                else => unreachable,
            },
            .rgb_color => switch (self.bit_depth) {
                8 => PixelFormat.rgb24,
                16 => PixelFormat.rgb48,
                else => unreachable,
            },
            .indexed => switch (self.bit_depth) {
                1 => PixelFormat.index1,
                2 => PixelFormat.index2,
                4 => PixelFormat.index4,
                8 => PixelFormat.index8,
                else => unreachable,
            },
            .grayscale_alpha => switch (self.bit_depth) {
                8 => PixelFormat.grayscale8Alpha,
                16 => PixelFormat.grayscale16Alpha,
                else => unreachable,
            },
            .rgba_color => switch (self.bit_depth) {
                8 => PixelFormat.rgba32,
                16 => PixelFormat.rgba64,
                else => unreachable,
            },
        };
    }
};
