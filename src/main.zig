pub const color = @import("color.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
