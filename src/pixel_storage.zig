const PixelFormat = @import("pixel_format.zig").PixelFormat;
const color = @import("color.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Grayscale1 = color.Grayscale1;
const Grayscale2 = color.Grayscale2;
const Grayscale4 = color.Grayscale4;
const Grayscale8 = color.Grayscale8;
const Grayscale8Alpha = color.Grayscale8Alpha;
const Grayscale16 = color.Grayscale16;
const Grayscale16Alpha = color.Grayscale16Alpha;
const Rgb24 = color.Rgb24;
const Rgba32 = color.Rgba32;
const Rgb565 = color.Rgb565;
const Rgb555 = color.Rgb555;
const Bgr24 = color.Bgr24;
const Bgra32 = color.Bgra32;
const Rgb48 = color.Rgb48;
const Rgba64 = color.Rgba64;
const Colorf32 = color.Colorf32;

pub fn IndexedStorage(comptime T: type) type {
    return struct {
        palette: []Colorf32,
        indices: []T,

        pub const PaletteSize = 1 << @bitSizeOf(T);

        const Self = @This();

        pub fn init(allocator: Allocator, pixel_count: usize) !Self {
            return Self{
                .indices = try allocator.alloc(T, pixel_count),
                .palette = try allocator.alloc(Colorf32, PaletteSize),
            };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(self.palette);
            allocator.free(self.indices);
        }
    };
}

pub const IndexedStorage1 = IndexedStorage(u1);
pub const IndexedStorage2 = IndexedStorage(u2);
pub const IndexedStorage4 = IndexedStorage(u4);
pub const IndexedStorage8 = IndexedStorage(u8);
pub const IndexedStorage16 = IndexedStorage(u16);

pub const PixelStorage = union(PixelFormat) {
    Bpp1: IndexedStorage1,
    Bpp2: IndexedStorage2,
    Bpp4: IndexedStorage4,
    Bpp8: IndexedStorage8,
    Bpp16: IndexedStorage16,
    Grayscale1: []Grayscale1,
    Grayscale2: []Grayscale2,
    Grayscale4: []Grayscale4,
    Grayscale8: []Grayscale8,
    Grayscale8Alpha: []Grayscale8Alpha,
    Grayscale16: []Grayscale16,
    Grayscale16Alpha: []Grayscale16Alpha,
    Rgb24: []Rgb24,
    Rgba32: []Rgba32,
    Rgb565: []Rgb565,
    Rgb555: []Rgb555,
    Bgr24: []Bgr24,
    Bgra32: []Bgra32,
    Rgb48: []Rgb48,
    Rgba64: []Rgba64,
    Float32: []Colorf32,

    const Self = @This();

    pub fn init(allocator: Allocator, format: PixelFormat, pixel_count: usize) !Self {
        return switch (format) {
            .Bpp1 => {
                return Self{
                    .Bpp1 = try IndexedStorage(u1).init(allocator, pixel_count),
                };
            },
            .Bpp2 => {
                return Self{
                    .Bpp2 = try IndexedStorage(u2).init(allocator, pixel_count),
                };
            },
            .Bpp4 => {
                return Self{
                    .Bpp4 = try IndexedStorage(u4).init(allocator, pixel_count),
                };
            },
            .Bpp8 => {
                return Self{
                    .Bpp8 = try IndexedStorage(u8).init(allocator, pixel_count),
                };
            },
            .Bpp16 => {
                return Self{
                    .Bpp16 = try IndexedStorage(u16).init(allocator, pixel_count),
                };
            },
            .Grayscale1 => {
                return Self{
                    .Grayscale1 = try allocator.alloc(Grayscale1, pixel_count),
                };
            },
            .Grayscale2 => {
                return Self{
                    .Grayscale2 = try allocator.alloc(Grayscale2, pixel_count),
                };
            },
            .Grayscale4 => {
                return Self{
                    .Grayscale4 = try allocator.alloc(Grayscale4, pixel_count),
                };
            },
            .Grayscale8 => {
                return Self{
                    .Grayscale8 = try allocator.alloc(Grayscale8, pixel_count),
                };
            },
            .Grayscale8Alpha => {
                return Self{
                    .Grayscale8Alpha = try allocator.alloc(Grayscale8Alpha, pixel_count),
                };
            },
            .Grayscale16 => {
                return Self{
                    .Grayscale16 = try allocator.alloc(Grayscale16, pixel_count),
                };
            },
            .Grayscale16Alpha => {
                return Self{
                    .Grayscale16Alpha = try allocator.alloc(Grayscale16Alpha, pixel_count),
                };
            },
            .Rgb24 => {
                return Self{
                    .Rgb24 = try allocator.alloc(Rgb24, pixel_count),
                };
            },
            .Rgba32 => {
                return Self{
                    .Rgba32 = try allocator.alloc(Rgba32, pixel_count),
                };
            },
            .Rgb565 => {
                return Self{
                    .Rgb565 = try allocator.alloc(Rgb565, pixel_count),
                };
            },
            .Rgb555 => {
                return Self{
                    .Rgb555 = try allocator.alloc(Rgb555, pixel_count),
                };
            },
            .Bgr24 => {
                return Self{
                    .Bgr24 = try allocator.alloc(Bgr24, pixel_count),
                };
            },
            .Bgra32 => {
                return Self{
                    .Bgra32 = try allocator.alloc(Bgra32, pixel_count),
                };
            },
            .Rgb48 => {
                return Self{
                    .Rgb48 = try allocator.alloc(Rgb48, pixel_count),
                };
            },
            .Rgba64 => {
                return Self{
                    .Rgba64 = try allocator.alloc(Rgba64, pixel_count),
                };
            },
            .Float32 => {
                return Self{
                    .Float32 = try allocator.alloc(Colorf32, pixel_count),
                };
            },
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        switch (self) {
            .Bpp1 => |data| data.deinit(allocator),
            .Bpp2 => |data| data.deinit(allocator),
            .Bpp4 => |data| data.deinit(allocator),
            .Bpp8 => |data| data.deinit(allocator),
            .Bpp16 => |data| data.deinit(allocator),
            .Grayscale1 => |data| allocator.free(data),
            .Grayscale2 => |data| allocator.free(data),
            .Grayscale4 => |data| allocator.free(data),
            .Grayscale8 => |data| allocator.free(data),
            .Grayscale8Alpha => |data| allocator.free(data),
            .Grayscale16 => |data| allocator.free(data),
            .Grayscale16Alpha => |data| allocator.free(data),
            .Rgb24 => |data| allocator.free(data),
            .Rgba32 => |data| allocator.free(data),
            .Rgb565 => |data| allocator.free(data),
            .Rgb555 => |data| allocator.free(data),
            .Bgr24 => |data| allocator.free(data),
            .Bgra32 => |data| allocator.free(data),
            .Rgb48 => |data| allocator.free(data),
            .Rgba64 => |data| allocator.free(data),
            .Float32 => |data| allocator.free(data),
        }
    }

    pub fn len(self: Self) usize {
        return switch (self) {
            .Bpp1 => |data| data.indices.len,
            .Bpp2 => |data| data.indices.len,
            .Bpp4 => |data| data.indices.len,
            .Bpp8 => |data| data.indices.len,
            .Bpp16 => |data| data.indices.len,
            .Grayscale1 => |data| data.len,
            .Grayscale2 => |data| data.len,
            .Grayscale4 => |data| data.len,
            .Grayscale8 => |data| data.len,
            .Grayscale8Alpha => |data| data.len,
            .Grayscale16 => |data| data.len,
            .Grayscale16Alpha => |data| data.len,
            .Rgb24 => |data| data.len,
            .Rgba32 => |data| data.len,
            .Rgb565 => |data| data.len,
            .Rgb555 => |data| data.len,
            .Bgr24 => |data| data.len,
            .Bgra32 => |data| data.len,
            .Rgb48 => |data| data.len,
            .Rgba64 => |data| data.len,
            .Float32 => |data| data.len,
        };
    }

    pub fn isIndexed(self: Self) bool {
        return switch (self) {
            .Bpp1 => true,
            .Bpp2 => true,
            .Bpp4 => true,
            .Bpp8 => true,
            .Bpp16 => true,
            else => false,
        };
    }
};

pub const PixelStorageIterator = struct {
    pixels: *const PixelStorage = undefined,
    current_index: usize = 0,
    end: usize = 0,

    const Self = @This();

    pub fn init(pixels: *const PixelStorage) Self {
        return Self{
            .pixels = pixels,
            .end = pixels.len(),
        };
    }

    pub fn initNull() Self {
        return Self{};
    }

    pub fn next(self: *Self) ?Colorf32 {
        if (self.current_index >= self.end) {
            return null;
        }

        const result: ?Colorf32 = switch (self.pixels.*) {
            .Bpp1 => |data| data.palette[data.indices[self.current_index]],
            .Bpp2 => |data| data.palette[data.indices[self.current_index]],
            .Bpp4 => |data| data.palette[data.indices[self.current_index]],
            .Bpp8 => |data| data.palette[data.indices[self.current_index]],
            .Bpp16 => |data| data.palette[data.indices[self.current_index]],
            .Grayscale1 => |data| data[self.current_index].toColorf32(),
            .Grayscale2 => |data| data[self.current_index].toColorf32(),
            .Grayscale4 => |data| data[self.current_index].toColorf32(),
            .Grayscale8 => |data| data[self.current_index].toColorf32(),
            .Grayscale8Alpha => |data| data[self.current_index].toColorf32(),
            .Grayscale16 => |data| data[self.current_index].toColorf32(),
            .Grayscale16Alpha => |data| data[self.current_index].toColorf32(),
            .Rgb24 => |data| data[self.current_index].toColorf32(),
            .Rgba32 => |data| data[self.current_index].toColorf32(),
            .Rgb565 => |data| data[self.current_index].toColorf32(),
            .Rgb555 => |data| data[self.current_index].toColorf32(),
            .Bgr24 => |data| data[self.current_index].toColorf32(),
            .Bgra32 => |data| data[self.current_index].toColorf32(),
            .Rgb48 => |data| data[self.current_index].toColorf32(),
            .Rgba64 => |data| data[self.current_index].toColorf32(),
            .Float32 => |data| data[self.current_index],
        };

        self.current_index += 1;
        return result;
    }
};

// ********************* TESTS *********************

test "Indexed Pixel Storage" {
    var storage = try PixelStorage.init(std.testing.allocator, .Bpp8, 64);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), storage.len());
    try std.testing.expect(storage.isIndexed());
    std.mem.set(u8, storage.Bpp8.indices, 0);
    storage.Bpp8.palette[0] = Colorf32.fromU32Rgba(0);
    storage.Bpp8.palette[1] = Colorf32.fromU32Rgba(0xffffffff);
    storage.Bpp8.indices[0] = 1;
    var iterator = PixelStorageIterator.init(&storage);
    var cnt: u32 = 0;
    var expected = Colorf32.fromU32Rgba(0xffffffff);
    while (iterator.next()) |item| {
        try std.testing.expectEqual(expected, item);
        expected = Colorf32.fromU32Rgba(0);
        cnt += 1;
    }
    try std.testing.expectEqual(@as(u32, 64), cnt);
}

test "RGBA Pixel Storage" {
    var storage = try PixelStorage.init(std.testing.allocator, .Rgba32, 64);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), storage.len());
    try std.testing.expect(!storage.isIndexed());
    std.mem.set(Rgba32, storage.Rgba32, Rgba32.fromValue(0));
    var iterator = PixelStorageIterator.init(&storage);
    storage.Rgba32.ptr[0] = Rgba32.fromValue(0xffffffff);
    var cnt: u32 = 0;
    var expected = Colorf32.fromU32Rgba(0xffffffff);
    while (iterator.next()) |item| {
        try std.testing.expectEqual(expected, item);
        expected = Colorf32.fromU32Rgba(0);
        cnt += 1;
    }
    try std.testing.expectEqual(@as(u32, 64), cnt);
}
