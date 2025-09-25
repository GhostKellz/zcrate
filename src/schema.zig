//! ZCrate Schema definition and validation

const std = @import("std");
const SerializationError = @import("root.zig").SerializationError;

pub const Schema = struct {
    version: u32,
    name: []const u8,
    fields: []const FieldDefinition,

    pub fn validate(self: Schema, comptime T: type) bool {
        const type_info = @typeInfo(T);
        switch (type_info) {
            .@"struct" => |struct_info| {
                // Allow for schema evolution - new fields can be added
                if (struct_info.fields.len < self.getRequiredFieldCount()) return false;

                inline for (struct_info.fields) |struct_field| {
                    const schema_field = self.findField(struct_field.name) orelse {
                        // Field not in schema - only allowed if field has default value in newer version
                        continue;
                    };
                    if (!isCompatibleType(struct_field.type, schema_field.field_type)) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    pub fn isCompatibleWith(self: Schema, other: Schema) bool {
        if (!std.mem.eql(u8, self.name, other.name)) return false;

        // Backward compatibility: newer schema can have additional optional fields
        if (other.version < self.version) {
            return self.isBackwardCompatibleWith(other);
        }

        // Forward compatibility: older schema should work with newer data (with defaults)
        if (self.version < other.version) {
            return other.isBackwardCompatibleWith(self);
        }

        return std.meta.eql(self.fields, other.fields);
    }

    pub fn getRequiredFieldCount(self: Schema) usize {
        var count: usize = 0;
        for (self.fields) |field| {
            if (field.required) count += 1;
        }
        return count;
    }

    pub fn findField(self: Schema, name: []const u8) ?FieldDefinition {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field;
        }
        return null;
    }

    fn isBackwardCompatibleWith(self: Schema, older: Schema) bool {
        // Check that all required fields from older schema exist in newer schema
        for (older.fields) |old_field| {
            if (!old_field.required) continue;

            const new_field = self.findField(old_field.name) orelse return false;
            if (!isCompatibleType(old_field.field_type, new_field.field_type)) return false;
        }
        return true;
    }
};

pub const FieldType = enum {
    Bool,
    U8, U16, U32, U64,
    I8, I16, I32, I64,
    F32, F64,
    String,
    Array,
    Struct,
};

pub const FieldDefinition = struct {
    name: []const u8,
    field_type: FieldType,
    required: bool = true,
    default_value: ?[]const u8 = null,
    added_in_version: u32 = 1,
    removed_in_version: ?u32 = null,

    pub fn isActiveInVersion(self: FieldDefinition, version: u32) bool {
        if (version < self.added_in_version) return false;
        if (self.removed_in_version) |removed| {
            if (version >= removed) return false;
        }
        return true;
    }

    pub fn hasDefault(self: FieldDefinition) bool {
        return self.default_value != null or !self.required;
    }
};

fn isCompatibleType(comptime T: type, field_type: FieldType) bool {
    return switch (@typeInfo(T)) {
        .bool => field_type == .Bool,
        .int => |int_info| switch (int_info.signedness) {
            .unsigned => switch (int_info.bits) {
                8 => field_type == .U8,
                16 => field_type == .U16,
                32 => field_type == .U32,
                64 => field_type == .U64,
                else => false,
            },
            .signed => switch (int_info.bits) {
                8 => field_type == .I8,
                16 => field_type == .I16,
                32 => field_type == .I32,
                64 => field_type == .I64,
                else => false,
            },
        },
        .float => |float_info| switch (float_info.bits) {
            32 => field_type == .F32,
            64 => field_type == .F64,
            else => false,
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8) field_type == .String else field_type == .Array,
            .many => if (ptr_info.child == u8 and ptr_info.is_const) field_type == .String else false,
            else => false,
        },
        .array => field_type == .Array,
        .@"struct" => field_type == .Struct,
        else => false,
    };
}

pub fn createSchema(comptime T: type, name: []const u8, version: u32) Schema {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |struct_info| {
            comptime var fields: [struct_info.fields.len]FieldDefinition = undefined;

            inline for (struct_info.fields, 0..) |field, i| {
                fields[i] = FieldDefinition{
                    .name = field.name,
                    .field_type = getFieldType(field.type),
                };
            }

            return Schema{
                .version = version,
                .name = name,
                .fields = &fields,
            };
        },
        else => @compileError("Schema can only be created for struct types"),
    }
}

fn getFieldType(comptime T: type) FieldType {
    return switch (@typeInfo(T)) {
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
            else => @compileError("Unsupported pointer type"),
        },
        .array => .Array,
        .@"struct" => .Struct,
        else => @compileError("Unsupported type for schema"),
    };
}

test "schema validation" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const schema = createSchema(TestStruct, "TestStruct", 1);
    try std.testing.expect(schema.validate(TestStruct));
}

test "schema field type mapping" {
    try std.testing.expectEqual(FieldType.Bool, getFieldType(bool));
    try std.testing.expectEqual(FieldType.U32, getFieldType(u32));
    try std.testing.expectEqual(FieldType.I64, getFieldType(i64));
    try std.testing.expectEqual(FieldType.F32, getFieldType(f32));
    try std.testing.expectEqual(FieldType.String, getFieldType([]const u8));
}