//! ZCrate Serializer implementation

const std = @import("std");
const types = @import("types.zig");
const SerializationError = @import("root.zig").SerializationError;

pub const Serializer = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, buffer: []u8) Serializer {
        return Serializer{
            .allocator = allocator,
            .buffer = buffer,
            .position = 0,
        };
    }

    pub fn serialize(self: *Serializer, data: anytype) !usize {
        const T = @TypeOf(data);
        const type_tag = types.getTypeTag(T);

        const header = types.Header{
            .type_tag = type_tag,
            .data_size = @intCast(types.sizeOf(T)),
        };

        try self.writeHeader(header);
        try self.writeData(T, data);

        return self.position;
    }

    fn writeHeader(self: *Serializer, header: types.Header) !void {
        try self.writeU32(header.magic);
        try self.writeU16(header.version);
        try self.writeU8(@intFromEnum(header.type_tag));
        try self.writeU32(header.data_size);
    }

    fn writeData(self: *Serializer, comptime T: type, data: T) !void {
        switch (@typeInfo(T)) {
            .bool => try self.writeBool(data),
            .int => try self.writeInt(T, data),
            .float => try self.writeFloat(T, data),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        try self.writeString(data);
                    } else {
                        try self.writeArray(ptr_info.child, data);
                    }
                },
                .many => {
                    if (ptr_info.child == u8 and ptr_info.is_const) {
                        const str = std.mem.span(data);
                        try self.writeString(str);
                    } else {
                        return SerializationError.UnsupportedType;
                    }
                },
                .one => {
                    // Handle string literals: *const [N:0]u8
                    switch (@typeInfo(ptr_info.child)) {
                        .array => |array_info| {
                            if (array_info.child == u8) {
                                const str = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
                                try self.writeString(str);
                            } else {
                                return SerializationError.UnsupportedType;
                            }
                        },
                        else => return SerializationError.UnsupportedType,
                    }
                },
                else => return SerializationError.UnsupportedType,
            },
            .array => |array_info| {
                try self.writeU32(@intCast(array_info.len));
                for (data) |item| {
                    try self.writeData(array_info.child, item);
                }
            },
            .@"struct" => |struct_info| {
                inline for (struct_info.fields) |field| {
                    try self.writeData(field.type, @field(data, field.name));
                }
            },
            else => return SerializationError.UnsupportedType,
        }
    }

    fn writeBool(self: *Serializer, value: bool) !void {
        try self.writeU8(if (value) 1 else 0);
    }

    fn writeInt(self: *Serializer, comptime T: type, value: T) !void {
        const bytes = std.mem.toBytes(value);
        try self.writeBytes(&bytes);
    }

    fn writeFloat(self: *Serializer, comptime T: type, value: T) !void {
        const bytes = std.mem.toBytes(value);
        try self.writeBytes(&bytes);
    }

    fn writeString(self: *Serializer, value: []const u8) !void {
        try self.writeU32(@intCast(value.len));
        try self.writeBytes(value);
    }

    fn writeArray(self: *Serializer, comptime T: type, value: []const T) !void {
        try self.writeU32(@intCast(value.len));
        for (value) |item| {
            try self.writeData(T, item);
        }
    }

    fn writeU8(self: *Serializer, value: u8) !void {
        if (self.position >= self.buffer.len) return SerializationError.BufferTooSmall;
        self.buffer[self.position] = value;
        self.position += 1;
    }

    fn writeU16(self: *Serializer, value: u16) !void {
        const bytes = std.mem.toBytes(value);
        try self.writeBytes(&bytes);
    }

    fn writeU32(self: *Serializer, value: u32) !void {
        const bytes = std.mem.toBytes(value);
        try self.writeBytes(&bytes);
    }

    fn writeBytes(self: *Serializer, bytes: []const u8) !void {
        if (self.position + bytes.len > self.buffer.len) return SerializationError.BufferTooSmall;
        @memcpy(self.buffer[self.position..self.position + bytes.len], bytes);
        self.position += bytes.len;
    }
};

test "serialize simple integer" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;

    var serializer = Serializer.init(allocator, &buffer);
    const size = try serializer.serialize(@as(i32, 42));

    try std.testing.expect(size > 0);
}

test "serialize string" {
    const allocator = std.testing.allocator;
    var buffer: [1024]u8 = undefined;

    var serializer = Serializer.init(allocator, &buffer);
    const size = try serializer.serialize("hello");

    try std.testing.expect(size > 0);
}