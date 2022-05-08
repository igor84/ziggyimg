const PixelFormat = @import("pixel_format.zig").PixelFormat;
const color = @import("color.zig");
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
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
        palette: []Rgba32,
        indices: []T,

        pub const palette_size = 1 << @bitSizeOf(T);

        const Self = @This();

        pub fn init(allocator: Allocator, pixel_count: usize) !Self {
            return Self{
                .indices = try allocator.alloc(T, pixel_count),
                .palette = try allocator.alloc(Rgba32, palette_size),
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
    index1: IndexedStorage1,
    index2: IndexedStorage2,
    index4: IndexedStorage4,
    index8: IndexedStorage8,
    index16: IndexedStorage16,
    grayscale1: []Grayscale1,
    grayscale2: []Grayscale2,
    grayscale4: []Grayscale4,
    grayscale8: []Grayscale8,
    grayscale8Alpha: []Grayscale8Alpha,
    grayscale16: []Grayscale16,
    grayscale16Alpha: []Grayscale16Alpha,
    rgb24: []Rgb24,
    rgba32: []Rgba32,
    rgb565: []Rgb565,
    rgb555: []Rgb555,
    bgr24: []Bgr24,
    bgra32: []Bgra32,
    rgb48: []Rgb48,
    rgba64: []Rgba64,
    float32: []Colorf32,

    const Self = @This();

    pub fn init(allocator: Allocator, format: PixelFormat, pixel_count: usize) !Self {
        return switch (format) {
            .index1 => {
                return Self{
                    .index1 = try IndexedStorage(u1).init(allocator, pixel_count),
                };
            },
            .index2 => {
                return Self{
                    .index2 = try IndexedStorage(u2).init(allocator, pixel_count),
                };
            },
            .index4 => {
                return Self{
                    .index4 = try IndexedStorage(u4).init(allocator, pixel_count),
                };
            },
            .index8 => {
                return Self{
                    .index8 = try IndexedStorage(u8).init(allocator, pixel_count),
                };
            },
            .index16 => {
                return Self{
                    .index16 = try IndexedStorage(u16).init(allocator, pixel_count),
                };
            },
            .grayscale1 => {
                return Self{
                    .grayscale1 = try allocator.alloc(Grayscale1, pixel_count),
                };
            },
            .grayscale2 => {
                return Self{
                    .grayscale2 = try allocator.alloc(Grayscale2, pixel_count),
                };
            },
            .grayscale4 => {
                return Self{
                    .grayscale4 = try allocator.alloc(Grayscale4, pixel_count),
                };
            },
            .grayscale8 => {
                return Self{
                    .grayscale8 = try allocator.alloc(Grayscale8, pixel_count),
                };
            },
            .grayscale8Alpha => {
                return Self{
                    .grayscale8Alpha = try allocator.alloc(Grayscale8Alpha, pixel_count),
                };
            },
            .grayscale16 => {
                return Self{
                    .grayscale16 = try allocator.alloc(Grayscale16, pixel_count),
                };
            },
            .grayscale16Alpha => {
                return Self{
                    .grayscale16Alpha = try allocator.alloc(Grayscale16Alpha, pixel_count),
                };
            },
            .rgb24 => {
                return Self{
                    .rgb24 = try allocator.alloc(Rgb24, pixel_count),
                };
            },
            .rgba32 => {
                return Self{
                    .rgba32 = try allocator.alloc(Rgba32, pixel_count),
                };
            },
            .rgb565 => {
                return Self{
                    .rgb565 = try allocator.alloc(Rgb565, pixel_count),
                };
            },
            .rgb555 => {
                return Self{
                    .rgb555 = try allocator.alloc(Rgb555, pixel_count),
                };
            },
            .bgr24 => {
                return Self{
                    .bgr24 = try allocator.alloc(Bgr24, pixel_count),
                };
            },
            .bgra32 => {
                return Self{
                    .bgra32 = try allocator.alloc(Bgra32, pixel_count),
                };
            },
            .rgb48 => {
                return Self{
                    .rgb48 = try allocator.alloc(Rgb48, pixel_count),
                };
            },
            .rgba64 => {
                return Self{
                    .rgba64 = try allocator.alloc(Rgba64, pixel_count),
                };
            },
            .float32 => {
                return Self{
                    .float32 = try allocator.alloc(Colorf32, pixel_count),
                };
            },
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        switch (self) {
            .index1 => |data| data.deinit(allocator),
            .index2 => |data| data.deinit(allocator),
            .index4 => |data| data.deinit(allocator),
            .index8 => |data| data.deinit(allocator),
            .index16 => |data| data.deinit(allocator),
            .grayscale1 => |data| allocator.free(data),
            .grayscale2 => |data| allocator.free(data),
            .grayscale4 => |data| allocator.free(data),
            .grayscale8 => |data| allocator.free(data),
            .grayscale8Alpha => |data| allocator.free(data),
            .grayscale16 => |data| allocator.free(data),
            .grayscale16Alpha => |data| allocator.free(data),
            .rgb24 => |data| allocator.free(data),
            .rgba32 => |data| allocator.free(data),
            .rgb565 => |data| allocator.free(data),
            .rgb555 => |data| allocator.free(data),
            .bgr24 => |data| allocator.free(data),
            .bgra32 => |data| allocator.free(data),
            .rgb48 => |data| allocator.free(data),
            .rgba64 => |data| allocator.free(data),
            .float32 => |data| allocator.free(data),
        }
    }

    pub fn len(self: Self) usize {
        return switch (self) {
            .index1 => |data| data.indices.len,
            .index2 => |data| data.indices.len,
            .index4 => |data| data.indices.len,
            .index8 => |data| data.indices.len,
            .index16 => |data| data.indices.len,
            .grayscale1 => |data| data.len,
            .grayscale2 => |data| data.len,
            .grayscale4 => |data| data.len,
            .grayscale8 => |data| data.len,
            .grayscale8Alpha => |data| data.len,
            .grayscale16 => |data| data.len,
            .grayscale16Alpha => |data| data.len,
            .rgb24 => |data| data.len,
            .rgba32 => |data| data.len,
            .rgb565 => |data| data.len,
            .rgb555 => |data| data.len,
            .bgr24 => |data| data.len,
            .bgra32 => |data| data.len,
            .rgb48 => |data| data.len,
            .rgba64 => |data| data.len,
            .float32 => |data| data.len,
        };
    }

    pub fn isIndexed(self: Self) bool {
        return switch (self) {
            .index1 => true,
            .index2 => true,
            .index4 => true,
            .index8 => true,
            .index16 => true,
            else => false,
        };
    }

    pub fn getPallete(self: Self) ?[]Rgba32 {
        return switch (self) {
            .index1 => |data| data.palette,
            .index2 => |data| data.palette,
            .index4 => |data| data.palette,
            .index8 => |data| data.palette,
            .index16 => |data| data.palette,
            else => null,
        };
    }

    pub fn pixelsAsBytes(self: Self) []u8 {
        return switch (self) {
            .index1 => |data| mem.sliceAsBytes(data.indices),
            .index2 => |data| mem.sliceAsBytes(data.indices),
            .index4 => |data| mem.sliceAsBytes(data.indices),
            .index8 => |data| mem.sliceAsBytes(data.indices),
            .index16 => |data| mem.sliceAsBytes(data.indices),
            .grayscale1 => |data| mem.sliceAsBytes(data),
            .grayscale2 => |data| mem.sliceAsBytes(data),
            .grayscale4 => |data| mem.sliceAsBytes(data),
            .grayscale8 => |data| mem.sliceAsBytes(data),
            .grayscale8Alpha => |data| mem.sliceAsBytes(data),
            .grayscale16 => |data| mem.sliceAsBytes(data),
            .grayscale16Alpha => |data| mem.sliceAsBytes(data),
            .rgb24 => |data| mem.sliceAsBytes(data),
            .rgba32 => |data| mem.sliceAsBytes(data),
            .rgb565 => |data| mem.sliceAsBytes(data),
            .rgb555 => |data| mem.sliceAsBytes(data),
            .bgr24 => |data| mem.sliceAsBytes(data),
            .bgra32 => |data| mem.sliceAsBytes(data),
            .rgb48 => |data| mem.sliceAsBytes(data),
            .rgba64 => |data| mem.sliceAsBytes(data),
            .float32 => |data| mem.sliceAsBytes(data),
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
            .index1 => |data| data.palette[data.indices[self.current_index]].toColorf32(),
            .index2 => |data| data.palette[data.indices[self.current_index]].toColorf32(),
            .index4 => |data| data.palette[data.indices[self.current_index]].toColorf32(),
            .index8 => |data| data.palette[data.indices[self.current_index]].toColorf32(),
            .index16 => |data| data.palette[data.indices[self.current_index]].toColorf32(),
            .grayscale1 => |data| data[self.current_index].toColorf32(),
            .grayscale2 => |data| data[self.current_index].toColorf32(),
            .grayscale4 => |data| data[self.current_index].toColorf32(),
            .grayscale8 => |data| data[self.current_index].toColorf32(),
            .grayscale8Alpha => |data| data[self.current_index].toColorf32(),
            .grayscale16 => |data| data[self.current_index].toColorf32(),
            .grayscale16Alpha => |data| data[self.current_index].toColorf32(),
            .rgb24 => |data| data[self.current_index].toColorf32(),
            .rgba32 => |data| data[self.current_index].toColorf32(),
            .rgb565 => |data| data[self.current_index].toColorf32(),
            .rgb555 => |data| data[self.current_index].toColorf32(),
            .bgr24 => |data| data[self.current_index].toColorf32(),
            .bgra32 => |data| data[self.current_index].toColorf32(),
            .rgb48 => |data| data[self.current_index].toColorf32(),
            .rgba64 => |data| data[self.current_index].toColorf32(),
            .float32 => |data| data[self.current_index],
        };

        self.current_index += 1;
        return result;
    }
};

// ********************* TESTS *********************

test "Indexed Pixel Storage" {
    var storage = try PixelStorage.init(std.testing.allocator, .index8, 64);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), storage.len());
    try std.testing.expect(storage.isIndexed());
    std.mem.set(u8, storage.index8.indices, 0);
    storage.index8.palette[0] = Rgba32.fromValue(0);
    storage.index8.palette[1] = Rgba32.fromValue(0xffffffff);
    storage.index8.indices[0] = 1;
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
    var storage = try PixelStorage.init(std.testing.allocator, .rgba32, 64);
    defer storage.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), storage.len());
    try std.testing.expect(!storage.isIndexed());
    std.mem.set(Rgba32, storage.rgba32, Rgba32.fromValue(0));
    var iterator = PixelStorageIterator.init(&storage);
    storage.rgba32.ptr[0] = Rgba32.fromValue(0xffffffff);
    var cnt: u32 = 0;
    var expected = Colorf32.fromU32Rgba(0xffffffff);
    while (iterator.next()) |item| {
        try std.testing.expectEqual(expected, item);
        expected = Colorf32.fromU32Rgba(0);
        cnt += 1;
    }
    try std.testing.expectEqual(@as(u32, 64), cnt);
}
