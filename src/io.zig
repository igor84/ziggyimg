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

        pub inline fn readStruct(self: *Self, comptime T: type) !*const T {
            switch (self.*) {
                .buffer => |*b| return b.readStruct(T),
                .file => |*f| return f.readStruct(T),
            }
        }
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

    fn BytesAsValueReturnType(comptime T: type, comptime B: type) type {
        return mem.CopyPtrAttrs(B, .One, T);
    }

    pub fn readStruct(self: *Self, comptime T: type) !*const T {
        // Only extern and packed structs have defined in-memory layout.
        comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
        const size = @sizeOf(T);
        var end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        var start = self.pos;
        self.pos = end;
        return @ptrCast(*const T, self.buffer[start..end]);
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

        pub fn readStruct(self: *Self, comptime T: type) !*const T {
            // Only extern and packed structs have defined in-memory layout.
            comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
            const size = @sizeOf(T);
            if (size > self.buffer.len) return error.EndOfStream; // TODO: What error to report?
            var readSize = try self.file.read(self.buffer[0..size]);
            if (readSize < size) return error.EndOfStream;
            return @ptrCast(*const T, self.buffer[0..]);
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

fn testReader(reader: *ImageReader8) !void {
    var array10 = try reader.readNoAlloc(10);
    try std.testing.expectEqualSlices(u8, "0123456789", array10);
    const TestStruct = packed struct {
        a: u32,
        b: [16]u8,
    };
    var ts = try reader.readStruct(TestStruct);
    try std.testing.expectEqual(TestStruct{
        .a = 0x64636241,
        .b = .{ 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', '0', '1' },
    }, ts.*);
    var buf: [8]u8 = undefined;
    var readBytes = try reader.read(buf[0..]);
    try std.testing.expectEqual(@as(usize, 8), readBytes);
    try std.testing.expectEqualSlices(u8, "23456789", buf[0..8]);
}

