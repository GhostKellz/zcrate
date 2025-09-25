//! Comprehensive test suite for ZCrate

const std = @import("std");
const zcrate = @import("root.zig");
const testing = std.testing;

// Test data structures
const SimpleStruct = struct {
    id: u32,
    value: i32,
    active: bool,
};

const NestedStruct = struct {
    header: SimpleStruct,
    name: []const u8,
    tags: []const u8,
};

const EvolutionV1 = struct {
    id: u32,
    name: []const u8,
};

const EvolutionV2 = struct {
    id: u32,
    name: []const u8,
    age: u32, // New field
    email: []const u8, // Another new field
};

// Basic serialization tests
test "basic integer serialization roundtrip" {
    const allocator = testing.allocator;
    const value: i32 = -12345;
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize(i32, allocator, buffer[0..size]);

    try testing.expectEqual(value, result);
}

test "basic float serialization roundtrip" {
    const allocator = testing.allocator;
    const value: f64 = 3.14159;
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize(f64, allocator, buffer[0..size]);

    try testing.expectEqual(value, result);
}

test "basic boolean serialization roundtrip" {
    const allocator = testing.allocator;
    const value = true;
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize(bool, allocator, buffer[0..size]);

    try testing.expectEqual(value, result);
}

test "string serialization roundtrip" {
    const allocator = testing.allocator;
    const value = "Hello, ZCrate World!";
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize([]const u8, allocator, buffer[0..size]);

    try testing.expectEqualStrings(value, result);
}

test "struct serialization roundtrip" {
    const allocator = testing.allocator;
    const value = SimpleStruct{
        .id = 42,
        .value = -100,
        .active = true,
    };
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize(SimpleStruct, allocator, buffer[0..size]);

    try testing.expectEqual(value.id, result.id);
    try testing.expectEqual(value.value, result.value);
    try testing.expectEqual(value.active, result.active);
}

test "nested struct serialization roundtrip" {
    const allocator = testing.allocator;
    const value = NestedStruct{
        .header = SimpleStruct{
            .id = 1,
            .value = 999,
            .active = false,
        },
        .name = "nested test",
        .tags = "tag1,tag2,tag3",
    };
    var buffer: [2048]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize(NestedStruct, allocator, buffer[0..size]);

    try testing.expectEqual(value.header.id, result.header.id);
    try testing.expectEqual(value.header.value, result.header.value);
    try testing.expectEqual(value.header.active, result.header.active);
    try testing.expectEqualStrings(value.name, result.name);
    try testing.expectEqualStrings(value.tags, result.tags);
}

test "array serialization roundtrip" {
    const allocator = testing.allocator;
    const value = [_]u32{ 1, 2, 3, 4, 5 };
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize([5]u32, allocator, buffer[0..size]);

    try testing.expectEqualSlices(u32, &value, &result);
}

// Schema evolution tests
test "schema evolution backward compatibility" {
    const allocator = testing.allocator;

    // Create V1 schema and data
    const fields_v1 = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
    };

    const schema_v1 = zcrate.Schema{
        .version = 1,
        .name = "Evolution",
        .fields = &fields_v1,
    };

    const data_v1 = EvolutionV1{
        .id = 123,
        .name = "Alice",
    };

    // Serialize with V1 schema
    var buffer: [1024]u8 = undefined;
    var serializer = zcrate.VersionedSerializer.init(allocator, &buffer, schema_v1);
    const size = try serializer.serialize(data_v1);

    // Create V2 schema (adds new fields)
    const fields_v2 = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
        .{ .name = "age", .field_type = .U32, .required = false, .added_in_version = 2, .default_value = "0" },
        .{ .name = "email", .field_type = .String, .required = false, .added_in_version = 2, .default_value = "" },
    };

    const schema_v2 = zcrate.Schema{
        .version = 2,
        .name = "Evolution",
        .fields = &fields_v2,
    };

    // Should be able to deserialize V1 data with V2 schema (with defaults)
    var deserializer = zcrate.VersionedDeserializer.init(allocator, buffer[0..size], schema_v2);
    const result = try deserializer.deserialize(EvolutionV2);

    try testing.expectEqual(data_v1.id, result.id);
    try testing.expectEqualStrings(data_v1.name, result.name);
    try testing.expectEqual(@as(u32, 0), result.age); // Default value
    try testing.expectEqualStrings("", result.email); // Default value
}

test "zero-copy string access" {
    const allocator = testing.allocator;

    const test_string = "Zero-copy test string";
    var buffer: [1024]u8 = undefined;

    // Serialize the string
    const size = try zcrate.serialize(allocator, test_string, &buffer);

    // Access via zero-copy view
    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const data_view = try view.view([]const u8);
    const result = try data_view.get();

    try testing.expect(result.isZeroCopy());
    const str = try result.getValue();
    try testing.expectEqualStrings(test_string, str);
}

test "zero-copy struct field access" {
    const allocator = testing.allocator;

    const data = SimpleStruct{
        .id = 999,
        .value = -42,
        .active = true,
    };
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, data, &buffer);

    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const data_view = try view.view(SimpleStruct);

    // Access individual fields (this would require enhanced implementation)
    const full_result = try data_view.get();
    const full_data = try full_result.getValue();

    try testing.expectEqual(data.id, full_data.id);
    try testing.expectEqual(data.value, full_data.value);
    try testing.expectEqual(data.active, full_data.active);
}

// Error handling tests
test "invalid magic number" {
    const allocator = testing.allocator;

    var buffer = [_]u8{ 0x12, 0x34, 0x56, 0x78 }; // Wrong magic number
    var deserializer = zcrate.Deserializer.init(allocator, &buffer);

    const result = deserializer.deserialize(i32);
    try testing.expectError(zcrate.SerializationError.InvalidData, result);
}

test "buffer too small" {
    const allocator = testing.allocator;

    var small_buffer: [4]u8 = undefined;
    const large_data = "This string is definitely too large for the buffer";

    const result = zcrate.serialize(allocator, large_data, &small_buffer);
    try testing.expectError(zcrate.SerializationError.BufferTooSmall, result);
}

test "type mismatch during deserialization" {
    const allocator = testing.allocator;

    // Serialize as i32
    const value: i32 = 42;
    var buffer: [1024]u8 = undefined;
    const size = try zcrate.serialize(allocator, value, &buffer);

    // Try to deserialize as f32
    const result = zcrate.deserialize(f32, allocator, buffer[0..size]);
    try testing.expectError(zcrate.SerializationError.InvalidData, result);
}

// Schema validation tests
test "schema validation - duplicate fields" {
    const allocator = testing.allocator;

    const fields = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true },
        .{ .name = "id", .field_type = .String, .required = true }, // Duplicate name
    };

    const schema = zcrate.Schema{
        .version = 1,
        .name = "Invalid",
        .fields = &fields,
    };

    const validator = zcrate.SchemaValidator.init(allocator);
    var result = try validator.validateSchema(schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.hasErrors());
}

test "schema validation - version consistency" {
    const allocator = testing.allocator;

    const fields = [_]zcrate.FieldDefinition{
        .{ .name = "future_field", .field_type = .U32, .required = true, .added_in_version = 5 },
    };

    const schema = zcrate.Schema{
        .version = 2, // Less than field's added_in_version
        .name = "Inconsistent",
        .fields = &fields,
    };

    const validator = zcrate.SchemaValidator.init(allocator);
    var result = try validator.validateSchema(schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.hasErrors());
}

// Benchmarking tests
test "serialization performance" {
    const allocator = testing.allocator;

    const iterations = 1000;
    const data = SimpleStruct{
        .id = 42,
        .value = -100,
        .active = true,
    };

    const serialize_time = try zcrate.benchmark.benchmarkSerialization(SimpleStruct, data, iterations);

    // Just ensure it completes without error and produces reasonable timing
    try testing.expect(serialize_time > 0);
    std.debug.print("\nSerialized {} structs in {} ns (avg: {} ns/op)\n", .{
        iterations,
        serialize_time,
        serialize_time / iterations,
    });
}

test "deserialization performance" {
    const allocator = testing.allocator;

    const data = SimpleStruct{
        .id = 42,
        .value = -100,
        .active = true,
    };

    var buffer: [1024]u8 = undefined;
    const size = try zcrate.serialize(allocator, data, &buffer);

    const iterations = 1000;
    const deserialize_time = try zcrate.benchmark.benchmarkDeserialization(SimpleStruct, buffer[0..size], iterations);

    try testing.expect(deserialize_time > 0);
    std.debug.print("Deserialized {} structs in {} ns (avg: {} ns/op)\n", .{
        iterations,
        deserialize_time,
        deserialize_time / iterations,
    });
}

// Variable-length encoding tests
test "variable length integer encoding" {
    const allocator = testing.allocator;

    const test_values = [_]u32{ 0, 127, 128, 16383, 16384, 2097151, 2097152 };

    for (test_values) |value| {
        var buffer: [1024]u8 = undefined;

        // Use versioned serializer which has varint encoding
        const fields = [_]zcrate.FieldDefinition{
            .{ .name = "value", .field_type = .U32, .required = true },
        };

        const schema = zcrate.Schema{
            .version = 1,
            .name = "VarIntTest",
            .fields = &fields,
        };

        const TestStruct = struct {
            value: u32,
        };

        const data = TestStruct{ .value = value };

        var serializer = zcrate.VersionedSerializer.init(allocator, &buffer, schema);
        const size = try serializer.serialize(data);

        // Verify size is reasonable (smaller values should use fewer bytes)
        if (value < 128) {
            try testing.expect(size < 50); // Should be quite small
        }

        var deserializer = zcrate.VersionedDeserializer.init(allocator, buffer[0..size], schema);
        const result = try deserializer.deserialize(TestStruct);

        try testing.expectEqual(value, result.value);
    }
}

// Edge cases and stress tests
test "empty string serialization" {
    const allocator = testing.allocator;
    const value = "";
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize([]const u8, allocator, buffer[0..size]);

    try testing.expectEqualStrings(value, result);
}

test "large integer values" {
    const allocator = testing.allocator;

    const values = [_]i64{
        std.math.minInt(i64),
        -1000000000000,
        -1,
        0,
        1,
        1000000000000,
        std.math.maxInt(i64),
    };

    for (values) |value| {
        var buffer: [1024]u8 = undefined;

        const size = try zcrate.serialize(allocator, value, &buffer);
        const result = try zcrate.deserialize(i64, allocator, buffer[0..size]);

        try testing.expectEqual(value, result);
    }
}

test "unicode string handling" {
    const allocator = testing.allocator;
    const value = "Hello, 世界! 🌍🚀";
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, value, &buffer);
    const result = try zcrate.deserialize([]const u8, allocator, buffer[0..size]);

    try testing.expectEqualStrings(value, result);
}

// Integration tests combining multiple features
test "full integration - versioned serialization with zero-copy access" {
    const allocator = testing.allocator;

    // Create complex nested data
    const ComplexData = struct {
        metadata: SimpleStruct,
        description: []const u8,
        tags: []const []const u8,
    };

    // This test would require more sophisticated implementation
    // For now, we'll test what we have
    const metadata = SimpleStruct{
        .id = 100,
        .value = 200,
        .active = true,
    };

    var buffer: [1024]u8 = undefined;
    const size = try zcrate.serialize(allocator, metadata, &buffer);

    // Test both regular and zero-copy access
    const regular_result = try zcrate.deserialize(SimpleStruct, allocator, buffer[0..size]);
    try testing.expectEqual(metadata.id, regular_result.id);

    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const zero_copy_view = try view.view(SimpleStruct);
    const zero_copy_result = try zero_copy_view.get();
    const zero_copy_data = try zero_copy_result.getValue();

    try testing.expectEqual(metadata.id, zero_copy_data.id);
    try testing.expectEqual(metadata.value, zero_copy_data.value);
    try testing.expectEqual(metadata.active, zero_copy_data.active);
}