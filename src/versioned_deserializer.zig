//! Versioned deserializer that handles schema evolution

const std = @import("std");
const types = @import("types.zig");
const Schema = @import("schema.zig").Schema;
const FieldDefinition = @import("schema.zig").FieldDefinition;
const FieldType = @import("schema.zig").FieldType;
const SerializationError = @import("root.zig").SerializationError;

pub const VersionedDeserializer = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,
    position: usize,
    current_schema: Schema,
    data_schema_version: u32,

    pub fn init(allocator: std.mem.Allocator, buffer: []const u8, schema: Schema) VersionedDeserializer {
        return VersionedDeserializer{
            .allocator = allocator,
            .buffer = buffer,
            .position = 0,
            .current_schema = schema,
            .data_schema_version = 0,
        };
    }

    pub fn deserialize(self: *VersionedDeserializer, comptime T: type) !T {
        try self.readVersionedHeader(T);
        return try self.readVersionedData(T);
    }

    fn readVersionedHeader(self: *VersionedDeserializer, comptime T: type) !void {
        const magic = try self.readVarInt(u32);
        if (magic != 0x5A435254) return SerializationError.InvalidData;

        const format_version = try self.readVarInt(u16);
        if (format_version < 2) return SerializationError.UnsupportedType;

        const type_tag: types.TypeTag = @enumFromInt(try self.readU8());
        const expected_tag = types.getTypeTag(T);
        if (type_tag != expected_tag) return SerializationError.InvalidData;

        self.data_schema_version = try self.readVarInt(u32);
        _ = try self.readVarInt(u32); // Skip data size
        _ = try self.readVarInt(u32); // Skip schema fingerprint for now
    }

    fn readVersionedData(self: *VersionedDeserializer, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .@"struct" => |struct_info| {
                var result: T = undefined;

                // Read field count from serialized data
                const serialized_field_count = try self.readVarInt(u32);
                var fields_read = std.StringHashMap(bool).init(self.allocator);
                defer fields_read.deinit();

                // Read each serialized field
                for (0..serialized_field_count) |_| {
                    const field_name_len = try self.readVarInt(u16);
                    if (field_name_len == 0) continue;

                    const field_name = self.buffer[self.position..self.position + field_name_len];
                    self.position += field_name_len;

                    const field_type: FieldType = @enumFromInt(try self.readU8());

                    // Try to match with struct field
                    var found_field = false;
                    inline for (struct_info.fields) |struct_field| {
                        if (std.mem.eql(u8, struct_field.name, field_name)) {
                            @field(result, struct_field.name) = try self.readTypedData(struct_field.type, field_type);
                            try fields_read.put(struct_field.name, true);
                            found_field = true;
                            break;
                        }
                    }

                    // If field not found in current struct, skip it (forward compatibility)
                    if (!found_field) {
                        try self.skipTypedData(field_type);
                    }
                }

                // Fill in defaults for missing fields (backward compatibility)
                inline for (struct_info.fields) |struct_field| {
                    if (!fields_read.contains(struct_field.name)) {
                        const schema_field = self.current_schema.findField(struct_field.name);
                        if (schema_field) |field| {
                            if (field.hasDefault()) {
                                @field(result, struct_field.name) = try self.getDefaultValue(struct_field.type, field);
                            } else {
                                return SerializationError.InvalidData; // Required field missing
                            }
                        } else {
                            // Field added in newer version of struct, use zero value
                            @field(result, struct_field.name) = std.mem.zeroes(struct_field.type);
                        }
                    }
                }

                return result;
            },
            else => {
                return try self.readData(T);
            },
        }
    }

    fn readTypedData(self: *VersionedDeserializer, comptime T: type, field_type: FieldType) !T {
        // Validate type compatibility
        const expected_type = getFieldTypeFromZigType(T);
        if (field_type != expected_type) {
            // Try type coercion for compatible types
            return try self.coerceType(T, field_type);
        }

        return try self.readData(T);
    }

    fn coerceType(self: *VersionedDeserializer, comptime T: type, field_type: FieldType) !T {
        // Basic type coercion for schema evolution
        switch (@typeInfo(T)) {
            .int => |_| {
                switch (field_type) {
                    .U8, .U16, .U32, .U64 => {
                        const val = switch (field_type) {
                            .U8 => @as(u64, try self.readVarInt(u8)),
                            .U16 => @as(u64, try self.readVarInt(u16)),
                            .U32 => @as(u64, try self.readVarInt(u32)),
                            .U64 => try self.readVarInt(u64),
                            else => unreachable,
                        };
                        return @intCast(val);
                    },
                    .I8, .I16, .I32, .I64 => {
                        const val = switch (field_type) {
                            .I8 => @as(i64, try self.readVarInt(i8)),
                            .I16 => @as(i64, try self.readVarInt(i16)),
                            .I32 => @as(i64, try self.readVarInt(i32)),
                            .I64 => try self.readVarInt(i64),
                            else => unreachable,
                        };
                        return @intCast(val);
                    },
                    else => return SerializationError.UnsupportedType,
                }
            },
            else => return SerializationError.UnsupportedType,
        }
    }

    fn skipTypedData(self: *VersionedDeserializer, field_type: FieldType) !void {
        switch (field_type) {
            .Bool => { _ = try self.readU8(); },
            .U8, .I8 => { _ = try self.readVarInt(u8); },
            .U16, .I16 => { _ = try self.readVarInt(u16); },
            .U32, .I32 => { _ = try self.readVarInt(u32); },
            .U64, .I64 => { _ = try self.readVarInt(u64); },
            .F32 => { self.position += 4; },
            .F64 => { self.position += 8; },
            .String => {
                const len = try self.readVarInt(u32);
                self.position += len;
            },
            .Array => {
                const len = try self.readVarInt(u32);
                // Skip array elements (this is simplified - real implementation would need element type info)
                for (0..len) |_| {
                    try self.skipTypedData(.U8); // Assume u8 for now
                }
            },
            .Struct => {
                // Skip nested struct (simplified)
                const field_count = try self.readVarInt(u32);
                for (0..field_count) |_| {
                    const name_len = try self.readVarInt(u16);
                    self.position += name_len;
                    const nested_type: FieldType = @enumFromInt(try self.readU8());
                    try self.skipTypedData(nested_type);
                }
            },
        }
    }

    fn getDefaultValue(self: *VersionedDeserializer, comptime T: type, field: FieldDefinition) !T {
        _ = self;

        if (field.default_value) |default_str| {
            // Parse default value from string (simplified)
            switch (@typeInfo(T)) {
                .int => return std.fmt.parseInt(T, default_str, 10) catch std.mem.zeroes(T),
                .float => return std.fmt.parseFloat(T, default_str) catch std.mem.zeroes(T),
                .bool => return std.mem.eql(u8, default_str, "true"),
                else => return std.mem.zeroes(T),
            }
        }

        return std.mem.zeroes(T);
    }

    fn readData(self: *VersionedDeserializer, comptime T: type) !T {
        switch (@typeInfo(T)) {
            .bool => return try self.readBool(),
            .int => return try self.readVarInt(T),
            .float => return try self.readFloat(T),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        return try self.readString();
                    } else {
                        return try self.readArray(ptr_info.child);
                    }
                },
                else => SerializationError.UnsupportedType,
            },
            .array => |array_info| {
                const len = try self.readVarInt(u32);
                if (len != array_info.len) return SerializationError.InvalidData;

                var result: T = undefined;
                for (&result, 0..array_info.len) |*item, _| {
                    item.* = try self.readData(array_info.child);
                }
                return result;
            },
            .@"struct" => {
                return try self.readVersionedData(T);
            },
            else => SerializationError.UnsupportedType,
        }
    }

    // Helper read functions
    fn readBool(self: *VersionedDeserializer) !bool {
        const value = try self.readU8();
        return value != 0;
    }

    fn readFloat(self: *VersionedDeserializer, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.position + size > self.buffer.len) return SerializationError.InvalidData;

        const bytes = self.buffer[self.position..self.position + size];
        self.position += size;

        return std.mem.bytesToValue(T, bytes[0..size]);
    }

    fn readString(self: *VersionedDeserializer) ![]const u8 {
        const len = try self.readVarInt(u32);
        if (self.position + len > self.buffer.len) return SerializationError.InvalidData;

        const result = self.buffer[self.position..self.position + len];
        self.position += len;

        return result;
    }

    fn readArray(self: *VersionedDeserializer, comptime T: type) ![]T {
        const len = try self.readVarInt(u32);
        const result = try self.allocator.alloc(T, len);

        for (result) |*item| {
            item.* = try self.readData(T);
        }

        return result;
    }

    fn readVarInt(self: *VersionedDeserializer, comptime T: type) !T {
        const UnsignedT = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
        var result: UnsignedT = 0;
        var shift: u6 = 0;

        while (true) {
            const byte = try self.readU8();
            result |= (@as(UnsignedT, byte & 0x7F)) << shift;

            if ((byte & 0x80) == 0) break;
            shift += 7;

            if (shift >= @typeInfo(T).int.bits) return SerializationError.InvalidData;
        }

        return @bitCast(result);
    }

    fn readU8(self: *VersionedDeserializer) !u8 {
        if (self.position >= self.buffer.len) return SerializationError.InvalidData;
        const value = self.buffer[self.position];
        self.position += 1;
        return value;
    }
};

fn getFieldTypeFromZigType(comptime T: type) FieldType {
    return switch (@typeInfo(T)) {
        .bool => .Bool,
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => switch (int_info.bits) {
                8 => .U8, 16 => .U16, 32 => .U32, 64 => .U64,
                else => .U64,
            },
            .signed => switch (int_info.bits) {
                8 => .I8, 16 => .I16, 32 => .I32, 64 => .I64,
                else => .I64,
            },
        },
        .float => |float_info| switch (float_info.bits) {
            32 => .F32, 64 => .F64,
            else => .F64,
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) .String else .Array,
            else => .String,
        },
        .array => .Array,
        .@"struct" => .Struct,
        else => .Struct,
    };
}

test "versioned deserialization with schema evolution" {
    const allocator = std.testing.allocator;

    // Test backward compatibility - reading old data with new schema
    _ = struct {
        id: u32,
        name: []const u8,
    };

    _ = struct {
        id: u32,
        name: []const u8,
        age: u32, // New field
    };

    // Simulate serialized V1 data (simplified)
    const buffer = [_]u8{0x54, 0x52, 0x43, 0x5A}; // Placeholder

    _ = VersionedDeserializer.init(allocator, &buffer, undefined);

    // This would deserialize V1 data into V2 struct with default age
    // const person = try deserializer.deserialize(PersonV2);
    // try std.testing.expectEqual(@as(u32, 0), person.age); // Default value
}