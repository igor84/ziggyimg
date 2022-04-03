const std = @import("std");
const utils = @import("../../utils.zig");
const bigToNative = std.mem.bigToNative;

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

pub const BitDepth = enum(u8) {
    bits1 = 1,
    bits2 = 2,
    bits4 = 4,
    bits8 = 8,
    bits16 = 16,

    const Self = @This();

    pub fn isValidForColorType(self: Self, colorType: ColorType) bool {
        switch (colorType) {
            .Grayscale => return utils.isEnumValid(self),
            .Indexed => return self == .bits1 or self == .bits2 or self == .bits4 or self == .bits8,
            else => return self == .bits8 or self == .bits16,
        }
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
    type: [4]u8,

    const Self = @This();

    pub fn length(self: Self) u32 {
        return bigToNative(u32, self.lengthBigEndian);
    }
};

pub const HeaderData = packed struct {
    pub const ChunkType = "IHDR";

    widthBigEndian: u32,
    heightBigEndian: u32,
    bitDepth: BitDepth,
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
        if (!self.bitDepth.isValidForColorType(self.colorType)) return false;
        return true;
    }
};
