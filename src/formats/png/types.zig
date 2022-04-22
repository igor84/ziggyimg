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
};
