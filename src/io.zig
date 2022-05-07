const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = std.builtin;
const assert = std.debug.assert;

pub const ImageReadError = error{EndOfStream} || std.os.ReadError || std.os.SeekError;

pub const ImageReader = union(enum) {
    buffer: BufferReader,
    file: FileReader,
    bufferp: *BufferReader,
    filep: *FileReader,

    const Self = @This();

    pub fn fromFile(file: std.fs.File) Self {
        return Self{ .file = FileReader.init(file) };
    }

    pub fn fromMemory(buffer: []const u8) Self {
        return Self{ .buffer = BufferReader.init(buffer) };
    }

    pub fn wrap(file_or_buffer: anytype) Self {
        if (@TypeOf(file_or_buffer) == *FileReader) return .{ .filep = file_or_buffer };
        if (@TypeOf(file_or_buffer) == *BufferReader) return .{ .bufferp = file_or_buffer };
        @compileError("ImageReader can only wrap FileReader and BufferReader");
    }

    pub inline fn readNoAlloc(self: *Self, size: usize) ImageReadError![]const u8 {
        switch (self.*) {
            .buffer => |*b| return b.readNoAlloc(size),
            .file => |*f| return f.readNoAlloc(size),
            .bufferp => |b| return b.readNoAlloc(size),
            .filep => |f| return f.readNoAlloc(size),
        }
    }

    pub inline fn read(self: *Self, buf: []u8) ImageReadError!usize {
        switch (self.*) {
            .buffer => |*b| return b.read(buf),
            .file => |*f| return f.read(buf),
            .bufferp => |b| return b.read(buf),
            .filep => |f| return f.read(buf),
        }
    }

    pub inline fn readStruct(self: *Self, comptime T: type) ImageReadError!*const T {
        switch (self.*) {
            .buffer => |*b| return b.readStruct(T),
            .file => |*f| return f.readStruct(T),
            .bufferp => |b| return b.readStruct(T),
            .filep => |f| return f.readStruct(T),
        }
    }

    pub inline fn readInt(self: *Self, comptime T: type) ImageReadError!T {
        switch (self.*) {
            .buffer => |*b| return b.readInt(T),
            .file => |*f| return f.readInt(T),
            .bufferp => |b| return b.readInt(T),
            .filep => |f| return f.readInt(T),
        }
    }

    pub fn readIntBig(self: *Self, comptime T: type) ImageReadError!T {
        switch (self.*) {
            .buffer => |*b| return b.readIntBig(T),
            .file => |*f| return f.readIntBig(T),
            .bufferp => |b| return b.readIntBig(T),
            .filep => |f| return f.readIntBig(T),
        }
    }

    pub fn readIntLittle(self: *Self, comptime T: type) ImageReadError!T {
        switch (self.*) {
            .buffer => |*b| return b.readIntLittle(T),
            .file => |*f| return f.readIntLittle(T),
            .bufferp => |b| return b.readIntLittle(T),
            .filep => |f| return f.readIntLittle(T),
        }
    }

    pub fn seekBy(self: *Self, amt: i64) ImageReadError!void {
        switch (self.*) {
            .buffer => |*b| return b.seekBy(amt),
            .file => |*f| return f.seekBy(amt),
            .bufferp => |b| return b.seekBy(amt),
            .filep => |f| return f.seekBy(amt),
        }
    }
};

pub const BufferReader = struct {
    buffer: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(buf: []const u8) Self {
        return .{ .buffer = buf, .pos = 0 };
    }

    pub fn readNoAlloc(self: *Self, size: usize) ImageReadError![]const u8 {
        const end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        const res = self.buffer[self.pos..end];
        self.pos = end;
        return res;
    }

    pub fn read(self: *Self, buf: []u8) ImageReadError!usize {
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

    pub fn readStruct(self: *Self, comptime T: type) ImageReadError!*const T {
        // Only extern and packed structs have defined in-memory layout.
        comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
        const size = @sizeOf(T);
        const end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        const start = self.pos;
        self.pos = end;
        return @ptrCast(*const T, self.buffer[start..end]);
    }

    pub fn readInt(self: *Self, comptime T: type) ImageReadError!T {
        comptime assert(@typeInfo(T) == .Int);
        const bitSize = @bitSizeOf(T);
        const size = @sizeOf(T);
        comptime assert(bitSize % 8 == 0 and bitSize / 8 == size); // This will not allow u24 as intended
        var result: T = undefined;
        const read_size = try self.read(mem.asBytes(&result));
        if (read_size != size) return error.EndOfStream;
        return result;
    }

    pub fn readIntBig(self: *Self, comptime T: type) ImageReadError!T {
        return mem.bigToNative(T, try self.readInt(T));
    }

    pub fn readIntLittle(self: *Self, comptime T: type) ImageReadError!T {
        return mem.littleToNative(T, try self.readInt(T));
    }

    pub fn seekBy(self: *Self, amt: i64) ImageReadError!void {
        if (amt < 0) {
            const abs_amt = std.math.absCast(amt);
            const abs_amt_usize = std.math.cast(usize, abs_amt) catch std.math.maxInt(usize);
            if (abs_amt_usize > self.pos) {
                self.pos = 0;
            } else {
                self.pos -= abs_amt_usize;
            }
        } else {
            const amt_usize = std.math.cast(usize, amt) catch std.math.maxInt(usize);
            const new_pos = self.pos +| amt_usize;
            self.pos = std.math.min(self.buffer.len, new_pos);
        }
    }

    pub const Reader = std.io.Reader(*Self, ImageReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
};

pub const FileReader = struct {
    file: std.fs.File,
    pos: usize = 0,
    end: usize = 0,
    buffer: [16 * 1024]u8 = undefined,

    const Self = @This();

    pub fn init(file: std.fs.File) Self {
        return Self{ .file = file };
    }

    pub fn readNoAlloc(self: *Self, size: usize) ImageReadError![]const u8 {
        if (size > self.buffer.len) return error.EndOfStream;
        var available = self.end - self.pos;
        if (available < size) {
            mem.copy(u8, self.buffer[0..available], self.buffer[self.pos..self.end]);
            const read_size = try self.file.read(self.buffer[available..]);
            self.pos = 0;
            available += read_size;
            self.end = available;
        }
        if (available < size) return error.EndOfStream;

        const endPos = self.pos + size;
        const result = self.buffer[self.pos..endPos];
        self.pos = endPos;
        return result;
    }

    pub fn read(self: *Self, buf: []u8) ImageReadError!usize {
        const size = buf.len;
        const available = self.end - self.pos;
        if (available >= size) {
            const endPos = self.pos + size;
            mem.copy(u8, buf[0..], self.buffer[self.pos..endPos]);
            self.pos = endPos;
            return size;
        }

        mem.copy(u8, buf[0..available], self.buffer[self.pos..self.end]);
        self.pos = 0;
        self.end = 0;
        return self.file.read(buf[available..]);
    }

    pub fn readStruct(self: *Self, comptime T: type) ImageReadError!*const T {
        // Only extern and packed structs have defined in-memory layout.
        comptime assert(@typeInfo(T).Struct.layout != std.builtin.TypeInfo.ContainerLayout.Auto);
        const size = @sizeOf(T);
        if (size > self.buffer.len) return error.EndOfStream;
        const buf = try self.readNoAlloc(size);
        return @ptrCast(*const T, buf);
    }

    pub fn readInt(self: *Self, comptime T: type) ImageReadError!T {
        comptime assert(@typeInfo(T) == .Int);
        const bit_size = @bitSizeOf(T);
        const size = @sizeOf(T);
        comptime assert(bit_size % 8 == 0 and bit_size / 8 == size); // This will not allow u24 as intended
        var result: T = undefined;
        const read_size = try self.read(mem.asBytes(&result));
        if (read_size != size) return error.EndOfStream;
        return result;
    }

    pub fn readIntBig(self: *Self, comptime T: type) ImageReadError!T {
        return mem.bigToNative(T, try self.readInt(T));
    }

    pub fn readIntLittle(self: *Self, comptime T: type) ImageReadError!T {
        return mem.littleToNative(T, try self.readInt(T));
    }

    pub fn seekBy(self: *Self, amt: i64) ImageReadError!void {
        if (amt < 0) {
            const abs_amt = std.math.absCast(amt);
            const abs_amt_usize = std.math.cast(usize, abs_amt) catch std.math.maxInt(usize);
            if (abs_amt_usize > self.pos) {
                try self.file.seekBy(amt + @intCast(i64, self.pos));
                self.pos = 0;
                self.end = 0;
            } else {
                self.pos -= abs_amt_usize;
            }
        } else {
            const amt_usize = std.math.cast(usize, amt) catch std.math.maxInt(usize);
            const new_pos = self.pos +| amt_usize;
            if (new_pos > self.end) {
                try self.file.seekBy(@intCast(i64, new_pos - self.end));
                self.pos = 0;
                self.end = 0;
            } else {
                self.pos = new_pos;
            }
        }
    }

    pub const Reader = std.io.Reader(*Self, ImageReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
};

// ********************* TESTS *********************

test "FileReader" {
    const cwd = std.fs.cwd();
    try cwd.writeFile("test.tmp", "0123456789Abcdefghijklmnopqr0123456789");
    defer cwd.deleteFile("test.tmp") catch {};
    const file = try cwd.openFile("test.tmp", .{ .mode = .read_only });
    defer file.close();
    var reader = ImageReader.fromFile(file);
    try testReader(&reader);
}

test "BufferReader" {
    const buffer = "0123456789Abcdefghijklmnopqr0123456789";
    var reader = ImageReader.fromMemory(buffer[0..]);
    try testReader(&reader);
}

fn testReader(reader: *ImageReader) !void {
    const array10 = try reader.readNoAlloc(10);
    try std.testing.expectEqualSlices(u8, "0123456789", array10);
    const TestStruct = packed struct {
        a: u32,
        b: [11]u8,
    };
    const ts = try reader.readStruct(TestStruct);
    try std.testing.expectEqual(TestStruct{
        .a = 0x64636241,
        .b = .{ 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o' },
    }, ts.*);
    var buf: [8]u8 = undefined;

    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        const read_bytes = try reader.read(buf[0..]);
        try std.testing.expectEqual(@as(usize, 8), read_bytes);
        try std.testing.expectEqualSlices(u8, "pqr01234", buf[0..8]);
        const int = try reader.readIntBig(u32);
        try std.testing.expectEqual(@as(u32, 0x35363738), int);
        try reader.seekBy(-@sizeOf(u32) - 8);
    }
}
