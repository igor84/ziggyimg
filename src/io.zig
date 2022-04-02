const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = std.builtin;
const assert = std.debug.assert;

pub fn ImageReader(comptime buffer_size_type: type) type {
    return union(enum) {
        const FReader = FileReader(buffer_size_type);

        buffer: BufferReader,
        file: FReader,

        pub const ReadError = std.fs.File.ReadError;
        pub const SeekError = std.fs.File.SeekError;
        pub const GetSeekPosError = std.fs.File.GetSeekPosError;

        const Self = @This();

        pub fn fromFile(file: std.fs.File) Self {
            return Self{ .file = FReader.init(file) };
        }

        pub fn fromMemory(buffer: []const u8) Self {
            return Self{ .buffer = BufferReader.init(buffer) };
        }

        pub inline fn readNoAlloc(self: *Self, size: buffer_size_type) ![]const u8 {
            switch (self.*) {
                .buffer => |*b| return b.readNoAlloc(size),
                .file => |*f| return f.readNoAlloc(size),
            }
        }

        pub inline fn read(self: *Self, buf: []u8) !usize {
            switch (self.*) {
                .buffer => |*b| return b.read(buf),
                .file => |*f| return f.read(buf),
            }
        }

        pub inline fn readStructNative(self: *Self, comptime T: type) !T {
            switch (self.*) {
                .buffer => |*b| return b.readStruct(T),
                .file => |*f| return f.readStruct(T),
            }
        }

        pub fn readStructForeign(self: *Self, comptime T: type) !T {
            var res = try self.readStructNative(T);
            byteSwapStruct(&res);
            return res;
        }

        fn byteSwapStruct(value: anytype) void {
            inline for (std.meta.fields(@TypeOf(value.*))) |field| {
                switch (@typeInfo(field.field_type)) {
                    .ComptimeInt, .Int => {
                        @field(value.*, field.name) = @byteSwap(field.field_type, @field(value.*, field.name));
                    },
                    .Enum => {
                        var fieldVal = @enumToInt(@field(value.*, field.name));
                        fieldVal = @byteSwap(@TypeOf(fieldVal), fieldVal);
                        @field(value.*, field.name) = @intToEnum(field.field_type, fieldVal);
                    },
                    .Struct => {
                        byteSwapStruct(&@field(value.*, field.name));
                    },
                    else => {
                        @compileError(std.fmt.comptimePrint("Type {} in byteSwapStruct not supported", .{@typeName(field.field_type)}));
                    },
                }
            }
        }

        const native_endian = @import("builtin").target.cpu.arch.endian();

        pub const readStructLittle = switch (native_endian) {
            builtin.Endian.Little => readStructNative,
            builtin.Endian.Big => readStructForeign,
        };

        pub const readStructBig = switch (native_endian) {
            builtin.Endian.Little => readStructForeign,
            builtin.Endian.Big => readStructNative,
        };
    };
}

const ImageReader8 = ImageReader(u8);
const ImageReader10 = ImageReader(u10);
const ImageReader12 = ImageReader(u12);
const ImageReader16 = ImageReader(u16);

const BufferReader = struct {
    buffer: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(buf: []const u8) Self {
        return .{ .buffer = buf, .pos = 0 };
    }

    pub fn readNoAlloc(self: *Self, size: usize) ![]const u8 {
        var end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        var res = self.buffer[self.pos..end];
        self.pos = end;
        return res;
    }

    pub fn read(self: *Self, buf: []u8) !usize {
        var size = buf.len;
        var end = self.pos + size;
        if (end > self.buffer.len) {
            end = self.buffer.len;
            size = end - self.pos;
        }
        mem.copy(u8, buf, self.buffer[self.pos..end]);
        self.pos = end;
        return size;
    }

    pub fn readStruct(self: *Self, comptime T: type) !T {
        // Only extern and packed structs have defined in-memory layout.
        comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
        const size = @sizeOf(T);
        var end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        var res: [1]T = undefined;
        var bytes = mem.sliceAsBytes(res[0..]);
        mem.copy(u8, bytes, self.buffer[self.pos..end]);
        self.pos = end;
        return res[0];
    }
};

pub fn FileReader(comptime buffer_size_type: type) type {
    const typeInfo = @typeInfo(buffer_size_type);
    if (typeInfo != .Int or typeInfo.Int.signedness != .unsigned or typeInfo.Int.bits < 8 or typeInfo.Int.bits > 18) {
        @compileError("The buffer size type must be unsigned int of at least 8 and at most 18 bits!");
    }
    return struct {
        buffer: [std.math.maxInt(buffer_size_type)]u8,
        file: std.fs.File,

        const Self = @This();

        pub fn init(file: std.fs.File) Self {
            return Self{ .file = file, .buffer = undefined };
        }

        pub fn readNoAlloc(self: *Self, size: buffer_size_type) ![]const u8 {
            if (size > self.buffer.len) return error.EndOfStream; // TODO: What error to report?
            var readSize = try self.file.read(self.buffer[0..size]);
            if (readSize < size) return error.EndOfStream;
            return self.buffer[0..size];
        }

        pub fn read(self: *Self, buf: []u8) !usize {
            try return self.file.read(buf);
        }

        pub fn readStruct(self: *Self, comptime T: type) !T {
            // Only extern and packed structs have defined in-memory layout.
            comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
            var res: [1]T = undefined;
            var bytes = mem.sliceAsBytes(res[0..]);
            const size = @sizeOf(T);
            var readSize = try self.file.read(bytes);
            if (readSize < size) return error.EndOfStream;
            return res[0];
        }
    };
}

const FileReader8 = FileReader(u8);
const FileReader10 = FileReader(u10);
const FileReader12 = FileReader(u12);
const FileReader16 = FileReader(u16);

// ********************* TESTS *********************

test "FileReader" {
    var cwd = std.fs.cwd();
    try cwd.writeFile("test.tmp", "0123456789Abcdefghijklmnopqr0123456789");
    defer cwd.deleteFile("test.tmp") catch {};
    var file = try cwd.openFile("test.tmp", .{ .mode = .read_only });
    defer file.close();
    var reader = ImageReader8.fromFile(file);
    try testReader(&reader);
}

test "BufferReader" {
    var buffer = "0123456789Abcdefghijklmnopqr0123456789";
    var reader = ImageReader8.fromMemory(buffer[0..]);
    try testReader(&reader);
}

test "ReadStructForeign" {
    const TestSubStruct = packed struct {
        int32f: u32,
        int8f: u8,
    };
    const TestStruct = packed struct {
        int32f: u32,
        int8f: u8,
        sub: TestSubStruct
    };
    var buffer = "01234567890123456789";
    var reader = ImageReader8.fromMemory(buffer[0..]);
    var nativeStruct = try reader.readStructNative(TestStruct);
    std.debug.print("\n{} {} {} {}\n", .{nativeStruct.int32f, nativeStruct.int8f, nativeStruct.sub.int32f, nativeStruct.sub.int8f});
    std.debug.print("{} {} {} {}\n", .{&nativeStruct.int32f, &nativeStruct.int8f, &nativeStruct.sub.int32f, &nativeStruct.sub.int8f});
    try std.testing.expectEqual(@as(usize, 10), reader.buffer.pos);
    var foreignStruct = try reader.readStructForeign(TestStruct);
    try std.testing.expectEqual(nativeStruct.int32f, @byteSwap(u32, foreignStruct.int32f));
    try std.testing.expectEqual(nativeStruct.int8f, foreignStruct.int8f);
    try std.testing.expectEqual(nativeStruct.sub.int32f, @byteSwap(u32, foreignStruct.sub.int32f));
    try std.testing.expectEqual(nativeStruct.sub.int8f, foreignStruct.sub.int8f);
}

fn testReader(reader: *ImageReader8) !void {
    var array10 = try reader.readNoAlloc(10);
    try std.testing.expectEqualSlices(u8, "0123456789", array10);
    const TestStruct = packed struct {
        a: u32,
        b: [16]u8,
    };
    var ts = try reader.readStructNative(TestStruct);
    try std.testing.expectEqual(TestStruct{
        .a = 0x64636241,
        .b = .{ 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 48, 49 },
    }, ts);
    var buf: [10]u8 = undefined;
    var readBytes = try reader.read(buf[0..]);
    try std.testing.expectEqual(@as(usize, 8), readBytes);
    try std.testing.expectEqualSlices(u8, "23456789", buf[0..8]);
}
