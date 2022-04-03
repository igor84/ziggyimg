const std = @import("std");

pub fn isEnumValid(enumValue: anytype) bool {
    const T = @TypeOf(enumValue);
    if (@typeInfo(T) != .Enum) @compileError("Expected enum type, found '" ++ @typeName(T) ++ "'");
    if (@hasField(T, "Count")) {
        return @enumToInt(@field(T, "Count")) > @enumToInt(enumValue);
    }
    inline for (std.meta.fields(T)) |field| {
        if (@field(T, field.name) == enumValue) return true;
    }
    return false;
}
