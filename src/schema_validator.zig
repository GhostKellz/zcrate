//! Schema validation and compatibility checking system

const std = @import("std");
const Schema = @import("schema.zig").Schema;
const FieldDefinition = @import("schema.zig").FieldDefinition;
const FieldType = @import("schema.zig").FieldType;
const SerializationError = @import("root.zig").SerializationError;
const ErrorContext = @import("root.zig").ErrorContext;

pub const ValidationResult = struct {
    valid: bool,
    errors: std.ArrayList(ErrorContext),
    warnings: std.ArrayList(ErrorContext),

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return ValidationResult{
            .valid = true,
            .errors = std.ArrayList(ErrorContext){},
            .warnings = std.ArrayList(ErrorContext){},
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit();
        self.warnings.deinit();
    }

    pub fn addError(self: *ValidationResult, allocator: std.mem.Allocator, error_ctx: ErrorContext) !void {
        self.valid = false;
        try self.errors.append(allocator, error_ctx);
    }

    pub fn addWarning(self: *ValidationResult, allocator: std.mem.Allocator, warning_ctx: ErrorContext) !void {
        try self.warnings.append(allocator, warning_ctx);
    }

    pub fn hasErrors(self: ValidationResult) bool {
        return self.errors.items.len > 0;
    }

    pub fn hasWarnings(self: ValidationResult) bool {
        return self.warnings.items.len > 0;
    }
};

pub const SchemaValidator = struct {
    allocator: std.mem.Allocator,
    strict_mode: bool = false,

    pub fn init(allocator: std.mem.Allocator) SchemaValidator {
        return SchemaValidator{
            .allocator = allocator,
        };
    }

    /// Validate a schema for internal consistency
    pub fn validateSchema(self: SchemaValidator, schema: Schema) !ValidationResult {
        var result = ValidationResult.init(self.allocator);

        // Check for duplicate field names
        try self.checkDuplicateFields(schema, &result);

        // Check field definitions
        try self.checkFieldDefinitions(schema, &result);

        // Check version consistency
        try self.checkVersionConsistency(schema, &result);

        return result;
    }

    /// Validate compatibility between two schemas (for migration)
    pub fn validateCompatibility(
        self: SchemaValidator,
        old_schema: Schema,
        new_schema: Schema,
    ) !ValidationResult {
        var result = ValidationResult.init(self.allocator);

        // Check schema names match
        if (!std.mem.eql(u8, old_schema.name, new_schema.name)) {
            try result.addError(ErrorContext{
                .error_code = SerializationError.IncompatibleSchema,
                .message = "Schema names do not match",
            });
            return result;
        }

        // Check version progression
        if (new_schema.version <= old_schema.version) {
            try result.addWarning(ErrorContext{
                .error_code = SerializationError.SchemaVersionMismatch,
                .message = "New schema version should be greater than old schema version",
            });
        }

        // Check field compatibility
        try self.checkFieldCompatibility(old_schema, new_schema, &result);

        // Check required fields
        try self.checkRequiredFields(old_schema, new_schema, &result);

        return result;
    }

    /// Validate that data conforms to a schema
    pub fn validateDataAgainstSchema(
        self: SchemaValidator,
        comptime T: type,
        schema: Schema,
    ) !ValidationResult {
        var result = ValidationResult.init(self.allocator);

        const type_info = @typeInfo(T);
        switch (type_info) {
            .@"struct" => |struct_info| {
                try self.validateStructFields(struct_info, schema, &result);
            },
            else => {
                try result.addError(ErrorContext{
                    .error_code = SerializationError.UnsupportedType,
                    .message = "Only struct types can be validated against schemas",
                });
            },
        }

        return result;
    }

    /// Check for circular references in nested schemas
    pub fn checkCircularReferences(
        self: SchemaValidator,
        schema: Schema,
        visited: *std.StringHashMap(bool),
    ) !ValidationResult {
        var result = ValidationResult.init(self.allocator);

        const schema_key = try std.fmt.allocPrint(self.allocator, "{s}:{}", .{ schema.name, schema.version });
        defer self.allocator.free(schema_key);

        if (visited.contains(schema_key)) {
            try result.addError(ErrorContext{
                .error_code = SerializationError.InvalidSchema,
                .message = "Circular reference detected in schema",
            });
            return result;
        }

        try visited.put(schema_key, true);

        // Check nested struct fields for circular references
        for (schema.fields) |field| {
            if (field.field_type == .Struct) {
                // This would require additional schema registry to resolve nested schemas
                // For now, we'll just add a warning
                try result.addWarning(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Nested struct field detected - circular reference check incomplete",
                    .field_name = field.name,
                });
            }
        }

        _ = visited.remove(schema_key);
        return result;
    }

    // Private validation methods

    fn checkDuplicateFields(self: SchemaValidator, schema: Schema, result: *ValidationResult) !void {
        _ = self;

        var seen = std.StringHashMap(bool).init(result.errors.allocator);
        defer seen.deinit();

        for (schema.fields) |field| {
            if (seen.contains(field.name)) {
                try result.addError(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Duplicate field name",
                    .field_name = field.name,
                });
            } else {
                try seen.put(field.name, true);
            }
        }
    }

    fn checkFieldDefinitions(self: SchemaValidator, schema: Schema, result: *ValidationResult) !void {
        _ = self;

        for (schema.fields) |field| {
            // Check field name is not empty
            if (field.name.len == 0) {
                try result.addError(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Field name cannot be empty",
                });
            }

            // Check version constraints
            if (field.added_in_version > schema.version) {
                try result.addError(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Field added in version later than schema version",
                    .field_name = field.name,
                });
            }

            if (field.removed_in_version) |removed_version| {
                if (removed_version <= field.added_in_version) {
                    try result.addError(ErrorContext{
                        .error_code = SerializationError.InvalidSchema,
                        .message = "Field removed in version before or same as added version",
                        .field_name = field.name,
                    });
                }
            }

            // Check default values for optional fields
            if (!field.required and field.default_value == null) {
                try result.addWarning(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Optional field without default value",
                    .field_name = field.name,
                });
            }
        }
    }

    fn checkVersionConsistency(self: SchemaValidator, schema: Schema, result: *ValidationResult) !void {
        _ = self;

        if (schema.version == 0) {
            try result.addError(ErrorContext{
                .error_code = SerializationError.InvalidSchema,
                .message = "Schema version cannot be zero",
            });
        }

        // Check that fields are consistent with schema version
        for (schema.fields) |field| {
            if (!field.isActiveInVersion(schema.version)) {
                try result.addWarning(ErrorContext{
                    .error_code = SerializationError.InvalidSchema,
                    .message = "Field is not active in schema version",
                    .field_name = field.name,
                });
            }
        }
    }

    fn checkFieldCompatibility(
        self: SchemaValidator,
        old_schema: Schema,
        new_schema: Schema,
        result: *ValidationResult,
    ) !void {

        for (old_schema.fields) |old_field| {
            const new_field_opt = new_schema.findField(old_field.name);

            if (new_field_opt) |new_field| {
                // Field exists in both schemas - check type compatibility
                if (old_field.field_type != new_field.field_type) {
                    if (!self.areTypesCompatible(old_field.field_type, new_field.field_type)) {
                        try result.addError(ErrorContext{
                            .error_code = SerializationError.FieldTypeMismatch,
                            .message = "Field type changed incompatibly",
                            .field_name = old_field.name,
                            .expected_type = @tagName(old_field.field_type),
                            .actual_type = @tagName(new_field.field_type),
                        });
                    } else {
                        try result.addWarning(ErrorContext{
                            .error_code = SerializationError.FieldTypeMismatch,
                            .message = "Field type changed but may be compatible",
                            .field_name = old_field.name,
                            .expected_type = @tagName(old_field.field_type),
                            .actual_type = @tagName(new_field.field_type),
                        });
                    }
                }

                // Check if required field became optional (OK) or optional became required (problematic)
                if (old_field.required and !new_field.required) {
                    // OK - field became optional
                } else if (!old_field.required and new_field.required) {
                    try result.addError(ErrorContext{
                        .error_code = SerializationError.BackwardCompatibilityError,
                        .message = "Optional field became required",
                        .field_name = old_field.name,
                    });
                }
            } else if (old_field.required) {
                // Required field was removed - this breaks compatibility
                try result.addError(ErrorContext{
                    .error_code = SerializationError.RequiredFieldMissing,
                    .message = "Required field was removed",
                    .field_name = old_field.name,
                });
            }
        }

        // Check new fields
        for (new_schema.fields) |new_field| {
            const old_field_opt = old_schema.findField(new_field.name);

            if (old_field_opt == null) {
                // New field added
                if (new_field.required and !new_field.hasDefault()) {
                    try result.addError(ErrorContext{
                        .error_code = SerializationError.BackwardCompatibilityError,
                        .message = "New required field without default value",
                        .field_name = new_field.name,
                    });
                }
            }
        }
    }

    fn checkRequiredFields(
        self: SchemaValidator,
        old_schema: Schema,
        new_schema: Schema,
        result: *ValidationResult,
    ) !void {
        _ = self;

        for (old_schema.fields) |old_field| {
            if (old_field.required) {
                const new_field_opt = new_schema.findField(old_field.name);
                if (new_field_opt == null) {
                    try result.addError(ErrorContext{
                        .error_code = SerializationError.RequiredFieldMissing,
                        .message = "Required field missing in new schema",
                        .field_name = old_field.name,
                    });
                }
            }
        }
    }

    fn validateStructFields(
        self: SchemaValidator,
        struct_info: std.builtin.Type.Struct,
        schema: Schema,
        result: *ValidationResult,
    ) !void {
        _ = self;

        // Check that all required schema fields have corresponding struct fields
        for (schema.fields) |schema_field| {
            if (!schema_field.required) continue;

            var found = false;
            inline for (struct_info.fields) |struct_field| {
                if (std.mem.eql(u8, struct_field.name, schema_field.name)) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                try result.addError(ErrorContext{
                    .error_code = SerializationError.RequiredFieldMissing,
                    .message = "Required schema field missing from struct",
                    .field_name = schema_field.name,
                });
            }
        }

        // Check that struct fields match schema types
        inline for (struct_info.fields) |struct_field| {
            const schema_field_opt = schema.findField(struct_field.name);
            if (schema_field_opt) |schema_field| {
                const expected_type = getFieldTypeFromZigType(struct_field.type);
                if (schema_field.field_type != expected_type) {
                    try result.addError(ErrorContext{
                        .error_code = SerializationError.FieldTypeMismatch,
                        .message = "Struct field type does not match schema",
                        .field_name = struct_field.name,
                        .expected_type = @tagName(schema_field.field_type),
                        .actual_type = @tagName(expected_type),
                    });
                }
            } else {
                try result.addWarning(ErrorContext{
                    .error_code = SerializationError.UnknownField,
                    .message = "Struct field not defined in schema",
                    .field_name = struct_field.name,
                });
            }
        }
    }

    fn areTypesCompatible(self: SchemaValidator, old_type: FieldType, new_type: FieldType) bool {
        _ = self;

        // Basic compatibility rules
        return switch (old_type) {
            // Integer widening is generally OK
            .U8 => new_type == .U8 or new_type == .U16 or new_type == .U32 or new_type == .U64,
            .U16 => new_type == .U16 or new_type == .U32 or new_type == .U64,
            .U32 => new_type == .U32 or new_type == .U64,
            .U64 => new_type == .U64,

            .I8 => new_type == .I8 or new_type == .I16 or new_type == .I32 or new_type == .I64,
            .I16 => new_type == .I16 or new_type == .I32 or new_type == .I64,
            .I32 => new_type == .I32 or new_type == .I64,
            .I64 => new_type == .I64,

            // Float widening is OK
            .F32 => new_type == .F32 or new_type == .F64,
            .F64 => new_type == .F64,

            // Exact matches required for other types
            .Bool, .String, .Array, .Struct => old_type == new_type,
        };
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

test "schema validation" {
    const allocator = std.testing.allocator;

    const fields = [_]FieldDefinition{
        FieldDefinition{
            .name = "id",
            .field_type = .U32,
            .required = true,
            .added_in_version = 1,
        },
        FieldDefinition{
            .name = "name",
            .field_type = .String,
            .required = true,
            .added_in_version = 1,
        },
    };

    const schema = Schema{
        .version = 1,
        .name = "Person",
        .fields = &fields,
    };

    const validator = SchemaValidator.init(allocator);
    var result = try validator.validateSchema(schema);
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}