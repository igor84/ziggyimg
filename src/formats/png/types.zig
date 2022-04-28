const std = @import("std");
const utils = @import("../../utils.zig");
const imgio = @import("../../io.zig");
const color = @import("../../color.zig");
const PixelFormat = @import("../../pixel_format.zig").PixelFormat;
const bigToNative = std.mem.bigToNative;
const Allocator = std.mem.Allocator;
const Colorf32 = color.Colorf32;

pub const ImageParsingError = error{InvalidData} || Allocator.Error || imgio.ImageReadError;

pub const MagicHeader = "\x89PNG\x0D\x0A\x1A\x0A";

pub const ColorType = enum(u8) {
    Grayscale = 0,
    RgbColor = 2,
    Indexed = 3,
    GrayscaleAlpha = 4,
    RgbaColor = 6,

    const Self = @This();

    pub fn channelCount(self: Self) u8 {
        return switch (self) {
            .Grayscale => 1,
            .RgbColor => 3,
            .Indexed => 1,
            .GrayscaleAlpha => 2,
            .RgbaColor => 4,
        };
    }
};

pub const FilterType = enum(u8) {
    None = 0,
    Sub = 1,
    Up = 2,
    Average = 3,
    Paeth = 4,
};

pub const InterlaceMethod = enum(u8) {
    None = 0,
    Adam7 = 1,
};

/// The compression methods supported by PNG
pub const CompressionMethod = enum(u8) { Deflate = 0 };

/// The filter methods supported by PNG
pub const FilterMethod = enum(u8) { Adaptive = 0 };

pub const ChunkHeader = packed struct {
    lengthBigEndian: u32,
    type: u32,

    const Self = @This();

    pub fn length(self: Self) u32 {
        return bigToNative(u32, self.lengthBigEndian);
    }
};

pub const ChunkProcessData = struct {
    rawReader: imgio.ImageReader,
    chunkLength: u32,
    currentFormat: PixelFormat,
    header: *const HeaderData,
    options: *const ReaderOptions, // TODO Replace options with tmpAllocator if that is all that remains
};

pub const PaletteProcessData = struct {
    palette: []Colorf32,
};

pub const RowProcessData = struct {
    destRow: []u8,
    srcFormat: PixelFormat,
    destFormat: PixelFormat,
    header: *const HeaderData,
    options: *const ReaderOptions,
};

pub const ReaderProcessor = struct {
    id: u32,
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        chunkProcessor: ?fn (context: *anyopaque, data: *ChunkProcessData) ImageParsingError!PixelFormat,
        paletteProcessor: ?fn (context: *anyopaque, data: *PaletteProcessData) ImageParsingError!void,
        dataRowProcessor: ?fn (context: *anyopaque, data: *RowProcessData) ImageParsingError!PixelFormat,
    };

    const Self = @This();

    pub inline fn processChunk(self: *Self, data: *ChunkProcessData) ImageParsingError!PixelFormat {
        return if (self.vtable.chunkProcessor) |cp| cp(self.context, data) else data.currentFormat;
    }

    pub inline fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        if (self.vtable.paletteProcessor) |pp| try pp(self.context, data);
    }

    pub inline fn processDataRow(self: *Self, data: *RowProcessData) ImageParsingError!PixelFormat {
        return if (self.vtable.dataRowProcessor) |drp| drp(self.context, data) else data.destFormat;
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
                .chunkProcessor = if (chunkProcessorFn == null) null else chunkProcessor,
                .paletteProcessor = if (paletteProcessorFn == null) null else paletteProcessor,
                .dataRowProcessor = if (dataRowProcessorFn == null) null else dataRowProcessor,
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
    const TRNSData = union(enum) { unset: u0, gray: u16, rgb: color.Rgb48, indexAlpha: []u8 };

    trnsData: TRNSData = .{ .unset = 0 },
    pltOrDataFound: bool = false,

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
        // We ignore if we encounter this chunk with colorType that already has alpha
        var resultFormat = data.currentFormat;
        if (self.pltOrDataFound) {
            _ = try data.rawReader.readNoAlloc(data.chunkLength + @sizeOf(u32)); // Skip invalid
            return resultFormat;
        }
        switch (data.header.colorType) {
            .Grayscale => {
                if (data.chunkLength == 2 and resultFormat.isJustGrayscale()) {
                    self.trnsData = .{ .gray = try data.rawReader.readIntBig(u16) };
                    resultFormat = if (data.header.bitDepth == 16) .Grayscale16Alpha else .Grayscale8Alpha;
                } else {
                    _ = try data.rawReader.readNoAlloc(data.chunkLength); // Skip invalid
                }
            },
            .Indexed => {
                if (data.chunkLength <= data.header.maxPaletteSize() and resultFormat.isIndex()) {
                    self.trnsData = .{ .indexAlpha = try data.options.tempAllocator.?.alloc(u8, data.chunkLength) };
                    var filled = try data.rawReader.read(self.trnsData.indexAlpha);
                    if (filled != self.trnsData.indexAlpha.len) return error.EndOfStream;
                } else {
                    _ = try data.rawReader.readNoAlloc(data.chunkLength); // Skip invalid
                }
            },
            .RgbColor => {
                if (data.chunkLength == @sizeOf(color.Rgb48) and resultFormat.isStandardRgb()) {
                    self.trnsData = .{ .rgb = (try data.rawReader.readStruct(color.Rgb48)).* };
                    resultFormat = if (data.header.bitDepth == 16) .Rgba64 else .Rgba32;
                } else {
                    _ = try data.rawReader.readNoAlloc(data.chunkLength); // Skip invalid
                }
            },
            else => _ = try data.rawReader.readNoAlloc(data.chunkLength), // Skip invalid
        }
        // Read but ignore Crc since this is not critical chunk
        _ = try data.rawReader.readNoAlloc(@sizeOf(u32));
        return resultFormat;
    }

    pub fn processPalette(self: *Self, data: *PaletteProcessData) ImageParsingError!void {
        self.pltOrDataFound = true;
        switch (self.trnsData) {
            .indexAlpha => |indexAlpha| {
                for (indexAlpha) |alpha, i| {
                    data.palette[i].a = color.toF32Color(alpha);
                }
            },
            else => unreachable,
        }
    }

    pub fn processDataRow(self: *Self, data: *RowProcessData) ImageParsingError!PixelFormat {
        self.pltOrDataFound = true;
        if (data.srcFormat.isIndex() or self.trnsData == .unset) return data.srcFormat;
        var pixelStride: u8 = switch (data.destFormat) {
            .Grayscale8Alpha, .Grayscale16Alpha => 2,
            .Rgba32, .Bgra32 => 4,
            .Rgba64 => 8,
            else => return data.srcFormat,
        };
        var pixelPos: u32 = 0;
        switch (self.trnsData) {
            .gray => |grayAlpha| {
                switch (data.srcFormat) {
                    .Grayscale1, .Grayscale2, .Grayscale4, .Grayscale8 => {
                        while (pixelPos + 1 < data.destRow.len) : (pixelPos += pixelStride) {
                            data.destRow[pixelPos + 1] = (data.destRow[pixelPos] ^ @truncate(u8, grayAlpha)) *| 255;
                        }
                        return .Grayscale8Alpha;
                    },
                    .Grayscale16 => {
                        var dest = std.mem.bytesAsSlice(u16, data.destRow);
                        while (pixelPos + 1 < dest.len) : (pixelPos += pixelStride) {
                            dest[pixelPos + 1] = (data.destRow[pixelPos] ^ grayAlpha) *| 65535;
                        }
                        return .Grayscale16Alpha;
                    },
                    else => unreachable,
                }
            },
            .rgb => |trColor| {
                switch (data.srcFormat) {
                    .Rgb24 => {
                        var dest = std.mem.bytesAsSlice(color.Rgba32, data.destRow);
                        pixelStride /= 4;
                        while (pixelPos < dest.len) : (pixelPos += pixelStride) {
                            var val = dest[pixelPos];
                            val.a = if (val.r == trColor.r and val.g == trColor.g and val.b == trColor.b) 0 else 255;
                            dest[pixelPos] = val;
                        }
                        return .Rgba32;
                    },
                    .Rgb48 => {
                        var dest = std.mem.bytesAsSlice(color.Rgba64, data.destRow);
                        pixelStride = 1;
                        while (pixelPos < dest.len) : (pixelPos += pixelStride) {
                            var val = dest[pixelPos];
                            val.a = if (val.r == trColor.r and val.g == trColor.g and val.b == trColor.b) 0 else 65535;
                            dest[pixelPos] = val;
                        }
                        return .Rgba64;
                    },
                    else => unreachable,
                }
            },
            else => unreachable,
        }
        return data.srcFormat;
    }
};

pub const ReaderOptions = struct {
    /// Allocator for temporary allocations. Max 500KiB will be allocated from it.
    /// If not provided Reader will use stack memory. Some temp allocations depend
    /// on image size so they will use the main allocator since we can't guarantee
    /// they are bounded. They will be allocated after the destination image to
    /// reduce memory fragmentation and freed internally.
    tempAllocator: ?Allocator = null,

    /// Should source image with palette be decoded as RGB image.
    /// If decodeTransparencyToAlpha is also true the image will be decoded into RGBA image.
    decodePaletteToRgb: bool = true,

    /// If there is a tRNS chunk decode it into alpha channel.
    decodeTransparencyToAlpha: bool = true,
    // This needs to
    // 1. decode and save tRNS chunk data => register chunk decoder
    // 2. when the result buffer needs to be allocated inform the system that it should contain the alpha channel => register customPixelFormatGetter
    // 3. After defilter process each pixel so alpha channel is added => register custom stream

    processors: []ReaderProcessor = defProcessors[0..],

    const Self = @This();
};

var defTrnsProcessor: TrnsProcessor = .{};
var defProcessors = [_]ReaderProcessor{defTrnsProcessor.processor()};

// Reading IDAT chunks:
// 1. IDatReader -> zlibStream -> defilterStream -> optionalStreams -> deinterlace or just copy to dest

pub const HeaderData = packed struct {
    pub const ChunkType = "IHDR";
    pub const ChunkTypeId = std.mem.bytesToValue(u32, ChunkType);

    widthBigEndian: u32,
    heightBigEndian: u32,
    bitDepth: u8,
    colorType: ColorType,
    compressionMethod: CompressionMethod,
    filterMethod: FilterMethod,
    interlaceMethod: InterlaceMethod,

    const Self = @This();

    pub fn width(self: *const Self) u32 {
        return bigToNative(u32, self.widthBigEndian);
    }

    pub fn height(self: *const Self) u32 {
        return bigToNative(u32, self.heightBigEndian);
    }

    pub fn isValid(self: *const Self) bool {
        const maxDim = std.math.maxInt(u32) >> 1;
        var w = self.width();
        var h = self.height();
        if (w == 0 or w > maxDim) return false;
        if (h == 0 or h > maxDim) return false;
        if (!utils.isEnumValid(self.colorType)) return false;
        if (!utils.isEnumValid(self.compressionMethod)) return false;
        if (!utils.isEnumValid(self.filterMethod)) return false;
        if (!utils.isEnumValid(self.interlaceMethod)) return false;

        var bd = self.bitDepth;
        return switch (self.colorType) {
            .Grayscale => bd == 1 or bd == 2 or bd == 4 or bd == 8 or bd == 16,
            .Indexed => bd == 1 or bd == 2 or bd == 4 or bd == 8,
            else => bd == 8 or bd == 16,
        };
    }

    pub fn allowsPalette(self: *const Self) bool {
        return self.colorType == .Indexed or
            self.colorType == .RgbColor or
            self.colorType == .RgbaColor;
    }

    pub fn maxPaletteSize(self: *const Self) u16 {
        return if (self.bitDepth > 8) 256 else @as(u16, 1) << @truncate(u4, self.bitDepth);
    }

    /// What will be the color type of resulting image with the given options
    pub fn destColorType(self: *const Self, options: *const ReaderOptions) ColorType {
        return switch (self.colorType) {
            .Grayscale => if (options.decodeTransparencyToAlpha) .GrayscaleAlpha else .Grayscale,
            .RgbColor => if (options.decodeTransparencyToAlpha) .RgbaColor else .RgbColor,
            .Indexed => if (options.decodePaletteToRgb) if (options.decodeTransparencyToAlpha) .RgbaColor else .RgbColor else .Indexed,
            .GrayscaleAlpha => .GrayscaleAlpha,
            .RgbaColor => .RgbaColor,
        };
    }

    pub fn channelCount(self: *const Self) u8 {
        return channelCountFrom(self.colorType);
    }

    pub fn destChannelCount(self: *const Self, options: *const ReaderOptions) u8 {
        return channelCountFrom(self.destColorType(options));
    }

    fn channelCountFrom(colorType: ColorType) u8 {
        return switch (colorType) {
            .Grayscale => 1,
            .RgbColor => 3,
            .Indexed => 1,
            .GrayscaleAlpha => 2,
            .RgbaColor => 4,
        };
    }

    pub fn pixelBits(self: *const Self) u8 {
        return self.bitDepth * self.channelCount();
    }

    pub fn destPixelBitSize(self: *const Self, options: *const ReaderOptions) u8 {
        self.bitDepth * self.destChannelCount(options);
    }

    pub fn lineBytes(self: *const Self) u32 {
        return (self.pixelBits() * self.width() + 7) / 8;
    }

    pub fn destLineBytes(self: *const Self, options: *const ReaderOptions) u32 {
        return (self.destPixelSize(options) * self.width() + 7) / 8;
    }

    pub fn getPixelFormat(self: *const Self) PixelFormat {
        return switch (self.colorType) {
            .Grayscale => switch (self.bitDepth) {
                1 => PixelFormat.Grayscale1,
                2 => PixelFormat.Grayscale2,
                4 => PixelFormat.Grayscale4,
                8 => PixelFormat.Grayscale8,
                16 => PixelFormat.Grayscale16,
                else => unreachable,
            },
            .RgbColor => switch (self.bitDepth) {
                8 => PixelFormat.Rgb24,
                16 => PixelFormat.Rgb48,
                else => unreachable,
            },
            .Indexed => switch (self.bitDepth) {
                1 => PixelFormat.Index1,
                2 => PixelFormat.Index2,
                4 => PixelFormat.Index4,
                8 => PixelFormat.Index8,
                else => unreachable,
            },
            .GrayscaleAlpha => switch (self.bitDepth) {
                8 => PixelFormat.Grayscale8Alpha,
                16 => PixelFormat.Grayscale16Alpha,
                else => unreachable,
            },
            .RgbaColor => switch (self.bitDepth) {
                8 => PixelFormat.Rgba32,
                16 => PixelFormat.Rgba64,
                else => unreachable,
            },
        };
    }
};
