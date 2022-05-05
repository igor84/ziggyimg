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

    pub fn name(self: Self) []const u8 {
        return std.mem.asBytes(&self.type);
    }
};

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
