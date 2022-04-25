const std = @import("std");
const utils = @import("../../utils.zig");
const bigToNative = std.mem.bigToNative;
const Allocator = std.mem.Allocator;
const PixelFormat = @import("../../pixel_format.zig").PixelFormat;

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
    Count,
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
};

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
        return if (self.bitDepth > 8) 256 else 1 << self.bitDepth;
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
        self.bitDepth * self.channelCount();
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
                1 => .Grayscale1,
                2 => .Grayscale2,
                4 => .Grayscale4,
                8 => .Grayscale8,
                16 => .Grayscale16,
            },
            .RgbColor => switch (self.bitDepth) {
                8 => .Rgb24,
                16 => .Rgb48,
            },
            .Indexed => switch (self.bitDepth) {
                1 => .Bpp1,
                2 => .Bpp2,
                4 => .Bpp4,
                8 => .Bpp8,
            },
            .GrayscaleAlpha => switch (self.bitDepth) {
                8 => .Grayscale8Alpha,
                16 => .Grayscale16Alpha,
            },
            .RgbaColor => switch (self.bitDepth) {
                8 => .Rgba32,
                16 => .Rgba64,
            },
        };
    }
};
