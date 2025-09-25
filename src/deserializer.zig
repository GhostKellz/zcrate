//! ZCrate Deserializer implementation

const std = @import("std");
const types = @import("types.zig");
const SerializationError = @import("root.zig").SerializationError;

pub const Deserializer = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8) Deserializer {
        return Deserializer{
            .allocator = allocator,
            .buffer = buffer,
            .position = 0,
        };
    }

    pub fn deserialize(self: *Deserializer, comptime T: type) !T {
        const header = try self.readHeader();

        const expected_tag = types.getTypeTag(T);
        if (header.type_tag != expected_tag) {
            return SerializationError.InvalidData;
        }

        return try self.readData(T);
    }

    fn readHeader(self: *Deserializer) !types.Header {
        const magic = try self.readU32();
        if (magic != 0x5A435254) return SerializationError.InvalidData;

        const version = try self.readU16();
        const type_tag: types.TypeTag = @enumFromInt(try self.readU8());
        const data_size = try self.readU32();

        return types.Header{
            .magic = magic,
            .version = version,
            .type_tag = type_tag,
            .data_size = data_size,
        };
    }

    fn readData(self: *Deserializer, comptime T: type) !T {
        return switch (@typeInfo(T)) {
            .bool => try self.readBool(),
            .int => try self.readInt(T),
            .float => try self.readFloat(T),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        return try self.readString();
                    } else {
                        return try self.readArray(ptr_info.child);
                    }
                },
                .many => {
                    if (ptr_info.child == u8 and ptr_info.is_const) {
                        return try self.readString();
                    } else {
                        return SerializationError.UnsupportedType;
                    }
                },
                else => SerializationError.UnsupportedType,
            },
            .array => |array_info| {
                const len = try self.readU32();
                if (len != array_info.len) return SerializationError.InvalidData;

                var result: T = undefined;
                for (&result, 0..array_info.len) |*item, _| {
                    item.* = try self.readData(array_info.child);
                }
                return result;
            },
            .@"struct" => |struct_info| {
                var result: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try self.readData(field.type);
                }
                return result;
            },
            else => SerializationError.UnsupportedType,
        };
    }

    fn readBool(self: *Deserializer) !bool {
        const value = try self.readU8();
        return value != 0;
    }

    fn readInt(self: *Deserializer, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.position + size > self.buffer.len) return SerializationError.InvalidData;

        const bytes = self.buffer[self.position..self.position + size];
        self.position += size;

        return std.mem.bytesToValue(T, bytes[0..size]);
    }

    fn readFloat(self: *Deserializer, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.position + size > self.buffer.len) return SerializationError.InvalidData;

        const bytes = self.buffer[self.position..self.position + size];
        self.position += size;

        return std.mem.bytesToValue(T, bytes[0..size]);
    }

    fn readString(self: *Deserializer) ![]const u8 {
        const len = try self.readU32();
        if (self.position + len > self.buffer.len) return SerializationError.InvalidData;

        const result = self.buffer[self.position..self.position + len];
        self.position += len;

        return result;
    }

    fn readArray(self: *Deserializer, comptime T: type) ![]T {
        const len = try self.readU32();
        const result = try self.allocator.alloc(T, len);

        for (result) |*item| {
            item.* = try self.readData(T);
        }

        return result;
    }

    fn readU8(self: *Deserializer) !u8 {
        if (self.position >= self.buffer.len) return SerializationError.InvalidData;
        const value = self.buffer[self.position];
        self.position += 1;
        return value;
    }

    fn readU16(self: *Deserializer) !u16 {
        const size = @sizeOf(u16);
        if (self.position + size > self.buffer.len) return SerializationError.InvalidData;

        const bytes = self.buffer[self.position..self.position + size];
        self.position += size;

        return std.mem.bytesToValue(u16, bytes[0..size]);
    }

    fn readU32(self: *Deserializer) !u32 {
        const size = @sizeOf(u32);
        if (self.position + size > self.buffer.len) return SerializationError.InvalidData;

        const bytes = self.buffer[self.position..self.position + size];
        self.position += size;

        return std.mem.bytesToValue(u32, bytes[0..size]);
    }
};

test "deserialize simple integer" {
    const allocator = std.testing.allocator;

    // Create a simple serialized buffer manually for testing
    var buffer: [1024]u8 = undefined;
    var pos: usize = 0;

    // Write header manually
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(u32, 0x5A435254))); // magic
    pos += 4;
    @memcpy(buffer[pos..pos+2], &std.mem.toBytes(@as(u16, 1))); // version
    pos += 2;
    buffer[pos] = @intFromEnum(types.TypeTag.I32); // type_tag
    pos += 1;
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(u32, 4))); // data_size
    pos += 4;
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(i32, 42))); // data
    pos += 4;

    var deserializer = Deserializer.init(allocator, buffer[0..pos]);
    const result = try deserializer.deserialize(i32);

    try std.testing.expectEqual(@as(i32, 42), result);
}