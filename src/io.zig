const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = std.builtin;
const assert = std.debug.assert;

pub const ImageReadError = error{ EndOfStream, SeekError } || std.os.ReadError;

pub fn ImageReader(comptime buffer_size_type: type) type {
    return union(enum) {
        const FReader = FileReader(buffer_size_type);

        buffer: BufferReader,
        file: FReader,

        const Self = @This();

        pub fn fromFile(file: std.fs.File) Self {
            return Self{ .file = FReader.init(file) };
        }

        pub fn fromMemory(buffer: []const u8) Self {
            return Self{ .buffer = BufferReader.init(buffer) };
        }

        pub inline fn readNoAlloc(self: *Self, size: buffer_size_type) ImageReadError![]const u8 {
            switch (self.*) {
                .buffer => |*b| return b.readNoAlloc(size),
                .file => |*f| return f.readNoAlloc(size),
            }
        }

        pub inline fn read(self: *Self, buf: []u8) ImageReadError!usize {
            switch (self.*) {
                .buffer => |*b| return b.read(buf),
                .file => |*f| return f.read(buf),
            }
        }

        pub inline fn readStruct(self: *Self, comptime T: type) ImageReadError!*const T {
            switch (self.*) {
                .buffer => |*b| return b.readStruct(T),
                .file => |*f| return f.readStruct(T),
            }
        }

        pub inline fn readInt(self: *Self, comptime T: type) ImageReadError!T {
            switch (self.*) {
                .buffer => |*b| return b.readInt(T),
                .file => |*f| return f.readInt(T),
            }
        }

        pub fn readIntBig(self: *Self, comptime T: type) ImageReadError!T {
            switch (self.*) {
                .buffer => |*b| return b.readIntBig(T),
                .file => |*f| return f.readIntBig(T),
            }
        }

        pub fn readIntLittle(self: *Self, comptime T: type) ImageReadError!T {
            switch (self.*) {
                .buffer => |*b| return b.readIntLittle(T),
                .file => |*f| return f.readIntLittle(T),
            }
        }

        pub fn seekBy(self: *Self, amt: i64) ImageReadError!void {
            switch (self.*) {
                .buffer => |*b| return b.seekBy(amt),
                .file => |*f| return f.seekBy(amt),
            }
        }
    };
}

pub const ImageReader8 = ImageReader(u8);
pub const ImageReader10 = ImageReader(u10);
pub const ImageReader12 = ImageReader(u12);
pub const ImageReader16 = ImageReader(u16);

pub const BufferReader = struct {
    buffer: []const u8,
    pos: usize,

    const Self = @This();

    pub fn init(buf: []const u8) Self {
        return .{ .buffer = buf, .pos = 0 };
    }

    pub fn readNoAlloc(self: *Self, size: usize) ImageReadError![]const u8 {
        var end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        var res = self.buffer[self.pos..end];
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
        var end = self.pos + size;
        if (end > self.buffer.len) return error.EndOfStream;
        var start = self.pos;
        self.pos = end;
        return @ptrCast(*const T, self.buffer[start..end]);
    }

    pub fn readInt(self: *Self, comptime T: type) ImageReadError!T {
        comptime assert(@typeInfo(T) == .Int);
        const bitSize = @bitSizeOf(T);
        const size = @sizeOf(T);
        comptime assert(bitSize % 8 == 0 and bitSize / 8 == size); // This will not allow u24 as intended
        var result: T = undefined;
        var readSize = try self.read(mem.asBytes(&result));
        if (readSize != size) return error.EndOfStream;
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
            const absAmt = std.math.absCast(amt);
            const absAmtUsize = std.math.cast(usize, absAmt) catch std.math.maxInt(usize);
            if (absAmtUsize > self.pos) {
                self.pos = 0;
            } else {
                self.pos -= absAmtUsize;
            }
        } else {
            const amtUsize = std.math.cast(usize, amt) catch std.math.maxInt(usize);
            const newPos = self.pos +| amtUsize;
            self.pos = std.math.min(self.buffer.len, newPos);
        }
    }

    pub const Reader = std.io.Reader(*Self, ImageReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }
};

pub fn FileReader(comptime buffer_size_type: type) type {
    const typeInfo = @typeInfo(buffer_size_type);
    if (typeInfo != .Int or typeInfo.Int.signedness != .unsigned or typeInfo.Int.bits < 8 or typeInfo.Int.bits > 18) {
        @compileError("The buffer size type must be unsigned int of at least 8 and at most 18 bits!");
    }
    const capacity = std.math.maxInt(buffer_size_type) + 1;
    return struct {
        file: std.fs.File,
        pos: usize = 0,
        end: usize = 0,
        buffer: [capacity]u8 = undefined,

        const Self = @This();

        pub fn init(file: std.fs.File) Self {
            return Self{ .file = file };
        }

        pub fn readNoAlloc(self: *Self, size: buffer_size_type) ImageReadError![]const u8 {
            var available = self.end - self.pos;
            if (available < size) {
                mem.copy(u8, self.buffer[0..available], self.buffer[self.pos..self.end]);
                var readSize = try self.file.read(self.buffer[available..]);
                self.pos = 0;
                available += readSize;
                self.end = available;
            }
            if (available < size) return error.EndOfStream;

            var endPos = self.pos + size;
            var result = self.buffer[self.pos..endPos];
            self.pos = endPos;
            return result;
        }

        pub fn read(self: *Self, buf: []u8) ImageReadError!usize {
            var size = buf.len;
            var available = self.end - self.pos;
            if (available >= size) {
                var endPos = self.pos + size;
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
            var buf = try self.readNoAlloc(size);
            return @ptrCast(*const T, buf);
        }

        pub fn readInt(self: *Self, comptime T: type) ImageReadError!T {
            comptime assert(@typeInfo(T) == .Int);
            const bitSize = @bitSizeOf(T);
            const size = @sizeOf(T);
            comptime assert(bitSize % 8 == 0 and bitSize / 8 == size); // This will not allow u24 as intended
            var result: T = undefined;
            var readSize = try self.read(mem.asBytes(&result));
            if (readSize != size) return error.EndOfStream;
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
                const absAmt = std.math.absCast(amt);
                const absAmtUsize = std.math.cast(usize, absAmt) catch std.math.maxInt(usize);
                self.pos -|= absAmtUsize;
            } else {
                const amtUsize = std.math.cast(usize, amt) catch std.math.maxInt(usize);
                const newPos = self.pos +| amtUsize;
                if (newPos > self.end) return error.SeekError;
                self.pos = newPos;
            }
        }

        pub const Reader = std.io.Reader(*Self, ImageReadError, read);

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub const FileReader8 = FileReader(u8);
pub const FileReader10 = FileReader(u10);
pub const FileReader12 = FileReader(u12);
pub const FileReader16 = FileReader(u16);

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
        b: [11]u8,
    };
    var ts = try reader.readStruct(TestStruct);
    try std.testing.expectEqual(TestStruct{
        .a = 0x64636241,
        .b = .{ 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o' },
    }, ts.*);
    var buf: [8]u8 = undefined;

    var i : u32 = 0;
    while (i < 2) : (i += 1) {
        var readBytes = try reader.read(buf[0..]);
        try std.testing.expectEqual(@as(usize, 8), readBytes);
        try std.testing.expectEqualSlices(u8, "pqr01234", buf[0..8]);
        var int = try reader.readIntBig(u32);
        try std.testing.expectEqual(@as(u32, 0x35363738), int);
        try reader.seekBy(-@sizeOf(u32) - 8);
    }
}
