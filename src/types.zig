//! Core type definitions for ZCrate serialization

const std = @import("std");

pub const TypeTag = enum(u8) {
    Null = 0x00,
    Bool = 0x01,
    U8 = 0x02,
    U16 = 0x03,
    U32 = 0x04,
    U64 = 0x05,
    I8 = 0x06,
    I16 = 0x07,
    I32 = 0x08,
    I64 = 0x09,
    F32 = 0x0A,
    F64 = 0x0B,
    String = 0x0C,
    Array = 0x0D,
    Struct = 0x0E,
};

pub fn getTypeTag(comptime T: type) TypeTag {
    return switch (@typeInfo(T)) {
        .@"null" => .Null,
        .bool => .Bool,
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => switch (int_info.bits) {
                8 => .U8,
                16 => .U16,
                32 => .U32,
                64 => .U64,
                else => @compileError("Unsupported unsigned integer bit width"),
            },
            .signed => switch (int_info.bits) {
                8 => .I8,
                16 => .I16,
                32 => .I32,
                64 => .I64,
                else => @compileError("Unsupported signed integer bit width"),
            },
        },
        .float => |float_info| switch (float_info.bits) {
            32 => .F32,
            64 => .F64,
            else => @compileError("Unsupported float bit width"),
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) .String else .Array,
            .many => if (ptr_info.child == u8 and ptr_info.is_const) .String else @compileError("Unsupported pointer type"),
            .one => {
                // Handle string literals: *const [N:0]u8
                return switch (@typeInfo(ptr_info.child)) {
                    .array => |array_info| if (array_info.child == u8) .String else @compileError("Unsupported pointer type"),
                    else => @compileError("Unsupported pointer type"),
                };
            },
            else => @compileError("Unsupported pointer type"),
        },
        .array => .Array,
        .@"struct" => .Struct,
        else => @compileError("Unsupported type for serialization"),
    };
}

pub const Header = struct {
    magic: u32 = 0x5A435254, // "ZCRT" in ASCII
    version: u16 = 1,
    type_tag: TypeTag,
    data_size: u32,
};

pub fn sizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |int_info| int_info.bits / 8,
        .float => |float_info| float_info.bits / 8,
        else => @sizeOf(T),
    };
}

test "type tag inference" {
    try std.testing.expectEqual(TypeTag.Bool, getTypeTag(bool));
    try std.testing.expectEqual(TypeTag.I32, getTypeTag(i32));
    try std.testing.expectEqual(TypeTag.U64, getTypeTag(u64));
    try std.testing.expectEqual(TypeTag.F32, getTypeTag(f32));
}