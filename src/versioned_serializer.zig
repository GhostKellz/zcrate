//! Versioned serializer that handles schema evolution

const std = @import("std");
const types = @import("types.zig");
const Schema = @import("schema.zig").Schema;
const FieldDefinition = @import("schema.zig").FieldDefinition;
const SerializationError = @import("root.zig").SerializationError;

pub const VersionedSerializer = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    position: usize,
    schema: Schema,

    pub fn init(allocator: std.mem.Allocator, buffer: []u8, schema: Schema) VersionedSerializer {
        return VersionedSerializer{
            .allocator = allocator,
            .buffer = buffer,
            .position = 0,
            .schema = schema,
        };
    }

    pub fn serialize(self: *VersionedSerializer, data: anytype) !usize {
        const T = @TypeOf(data);

        // Write versioned header
        try self.writeVersionedHeader(T);

        // Write data with schema awareness
        try self.writeVersionedData(T, data);

        return self.position;
    }

    fn writeVersionedHeader(self: *VersionedSerializer, comptime T: type) !void {
        try self.writeU32(0x5A435254); // Magic "ZCRT"
        try self.writeU16(2); // Version 2 - supports schema evolution
        try self.writeU8(@intFromEnum(types.getTypeTag(T)));
        try self.writeU32(self.schema.version); // Schema version
        try self.writeU32(0); // Data size placeholder - will be updated later

        // Write schema fingerprint for validation
        try self.writeSchemaFingerprint();
    }

    fn writeSchemaFingerprint(self: *VersionedSerializer) !void {
        // Simple hash of schema name and version for validation
        const hash = std.hash_map.hashString(self.schema.name) ^ self.schema.version;
        try self.writeU32(@truncate(hash));
    }

    fn writeVersionedData(self: *VersionedSerializer, comptime T: type, data: T) !void {
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                // Write field count (simplified for demo)
                try self.writeU32(@intCast(struct_info.fields.len));

                // Write each field with metadata (simplified for demo)
                inline for (struct_info.fields) |field| {
                    // Write field header: name length, name, simplified type
                    try self.writeU16(@intCast(field.name.len));
                    try self.writeBytes(field.name);

                    const field_type_tag = types.getTypeTag(field.type);
                    try self.writeU8(@intFromEnum(field_type_tag));

                    // Write field data
                    try self.writeData(field.type, @field(data, field.name));
                }
            },
            else => {
                try self.writeData(T, data);
            },
        }
    }

    fn writeData(self: *VersionedSerializer, comptime T: type, data: T) !void {
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
            .@"struct" => {
                // Nested struct - recursively serialize
                try self.writeVersionedData(T, data);
            },
            else => return SerializationError.UnsupportedType,
        }
    }

    // Helper write functions
    fn writeBool(self: *VersionedSerializer, value: bool) !void {
        try self.writeU8(if (value) 1 else 0);
    }

    fn writeInt(self: *VersionedSerializer, comptime T: type, value: T) !void {
        // Use variable-length encoding for integers
        try self.writeVarInt(T, value);
    }

    fn writeFloat(self: *VersionedSerializer, comptime T: type, value: T) !void {
        const bytes = std.mem.toBytes(value);
        try self.writeBytes(&bytes);
    }

    fn writeString(self: *VersionedSerializer, value: []const u8) !void {
        try self.writeVarInt(u32, @intCast(value.len));
        try self.writeBytes(value);
    }

    fn writeArray(self: *VersionedSerializer, comptime T: type, value: []const T) !void {
        try self.writeVarInt(u32, @intCast(value.len));
        for (value) |item| {
            try self.writeData(T, item);
        }
    }

    fn writeVarInt(self: *VersionedSerializer, comptime T: type, value: T) !void {
        const UnsignedT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
        var val: UnsignedT = @bitCast(value);

        while (val >= 128) {
            try self.writeU8(@intCast((val & 0x7F) | 0x80));
            val >>= 7;
        }
        try self.writeU8(@intCast(val & 0x7F));
    }

    fn writeU8(self: *VersionedSerializer, value: u8) !void {
        if (self.position >= self.buffer.len) return SerializationError.BufferTooSmall;
        self.buffer[self.position] = value;
        self.position += 1;
    }

    fn writeU16(self: *VersionedSerializer, value: u16) !void {
        try self.writeVarInt(u16, value);
    }

    fn writeU32(self: *VersionedSerializer, value: u32) !void {
        try self.writeVarInt(u32, value);
    }

    fn writeBytes(self: *VersionedSerializer, bytes: []const u8) !void {
        if (self.position + bytes.len > self.buffer.len) return SerializationError.BufferTooSmall;
        @memcpy(self.buffer[self.position..self.position + bytes.len], bytes);
        self.position += bytes.len;
    }
};

test "versioned serialization" {
    const allocator = std.testing.allocator;

    const PersonV1 = struct {
        id: u32,
        name: []const u8,
    };

    var buffer: [1024]u8 = undefined;

    const fields = [_]FieldDefinition{
        FieldDefinition{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        FieldDefinition{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
    };

    const schema = Schema{
        .version = 1,
        .name = "Person",
        .fields = &fields,
    };

    var serializer = VersionedSerializer.init(allocator, &buffer, schema);

    const person = PersonV1{
        .id = 123,
        .name = "Alice",
    };

    const size = try serializer.serialize(person);
    try std.testing.expect(size > 0);
}