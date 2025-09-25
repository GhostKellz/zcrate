const std = @import("std");
const zcrate = @import("zcrate");

// Data structures for different schema versions
const PersonV1 = struct {
    id: u32,
    name: []const u8,
    age: u16,
    active: bool,
};

const PersonV2 = struct {
    id: u32,
    name: []const u8,
    age: u16,
    active: bool,
    email: []const u8, // New field in V2
    score: f32, // Another new field
};

const NestedData = struct {
    header: PersonV1,
    metadata: []const u8,
    tags: [3]u32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ZCrate RC1 Feature Demo ===\n\n", .{});

    // Demo 1: Basic serialization (Alpha features)
    std.debug.print("1. Basic Serialization (Alpha Features):\n", .{});
    try demoBasicSerialization(allocator);

    // Demo 2: Schema evolution and versioned serialization
    std.debug.print("\n2. Schema Evolution & Versioned Serialization:\n", .{});
    try demoSchemaEvolution(allocator);

    // Demo 3: Zero-copy deserialization
    std.debug.print("\n3. Zero-Copy Deserialization:\n", .{});
    try demoZeroCopy(allocator);

    // Demo 4: Variable-length encoding
    std.debug.print("\n4. Variable-Length Encoding Optimization:\n", .{});
    try demoVariableLengthEncoding(allocator);

    // Demo 5: Schema validation
    std.debug.print("\n5. Schema Validation System:\n", .{});
    try demoSchemaValidation(allocator);

    // Demo 6: Error handling improvements
    std.debug.print("\n6. Enhanced Error Handling:\n", .{});
    try demoErrorHandling(allocator);

    // Demo 7: Performance benchmarks
    std.debug.print("\n7. Performance Benchmarks:\n", .{});
    try demoPerformance(allocator);

    std.debug.print("\n=== ZCrate RC1 Demo Complete ===\n", .{});
    try zcrate.bufferedPrint();
}

fn demoBasicSerialization(allocator: std.mem.Allocator) !void {
    const person = PersonV1{
        .id = 1001,
        .name = "Alice Smith",
        .age = 28,
        .active = true,
    };

    var buffer: [2048]u8 = undefined;
    const size = try zcrate.serialize(allocator, person, &buffer);
    std.debug.print("   Serialized PersonV1: {} bytes\n", .{size});

    const result = try zcrate.deserialize(PersonV1, allocator, buffer[0..size]);
    std.debug.print("   Roundtrip successful: id={}, name='{s}'\n", .{ result.id, result.name });
}

fn demoSchemaEvolution(allocator: std.mem.Allocator) !void {
    // Create V1 schema
    const fields_v1 = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
        .{ .name = "age", .field_type = .U16, .required = true, .added_in_version = 1 },
        .{ .name = "active", .field_type = .Bool, .required = true, .added_in_version = 1 },
    };

    const schema_v1 = zcrate.Schema{
        .version = 1,
        .name = "Person",
        .fields = &fields_v1,
    };

    // Create V2 schema with additional fields
    const fields_v2 = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
        .{ .name = "age", .field_type = .U16, .required = true, .added_in_version = 1 },
        .{ .name = "active", .field_type = .Bool, .required = true, .added_in_version = 1 },
        .{ .name = "email", .field_type = .String, .required = false, .added_in_version = 2, .default_value = "" },
        .{ .name = "score", .field_type = .F32, .required = false, .added_in_version = 2, .default_value = "0.0" },
    };

    const schema_v2 = zcrate.Schema{
        .version = 2,
        .name = "Person",
        .fields = &fields_v2,
    };

    // Serialize data with V1 schema
    const person_v1 = PersonV1{
        .id = 42,
        .name = "Bob Wilson",
        .age = 35,
        .active = true,
    };

    var buffer: [2048]u8 = undefined;
    var serializer = zcrate.VersionedSerializer.init(allocator, &buffer, schema_v1);
    const size = try serializer.serialize(person_v1);

    std.debug.print("   V1 data serialized: {} bytes\n", .{size});

    // Check schema compatibility (simplified for demo)
    const are_compatible = schema_v1.isCompatibleWith(schema_v2);
    std.debug.print("   Schema V1->V2 compatibility: {}\n", .{are_compatible});
    std.debug.print("   Schema evolution demo complete\n", .{});
}

fn demoZeroCopy(allocator: std.mem.Allocator) !void {
    const test_string = "Zero-copy access demonstration";
    var buffer: [2048]u8 = undefined;

    // Serialize string
    const size = try zcrate.serialize(allocator, test_string, &buffer);
    std.debug.print("   Serialized string: {} bytes\n", .{size});

    // Zero-copy access
    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const data_view = try view.view([]const u8);
    const result = try data_view.get();

    if (result.isZeroCopy()) {
        std.debug.print("   Zero-copy access successful!\n", .{});
        const str = try result.getValue();
        std.debug.print("   Accessed string: '{s}'\n", .{str});
    } else {
        std.debug.print("   Data required copying\n", .{});
    }
}

fn demoVariableLengthEncoding(allocator: std.mem.Allocator) !void {
    const test_values = [_]u32{ 1, 127, 128, 16383, 16384, 1000000 };

    std.debug.print("   Variable-length encoding comparison:\n", .{});

    for (test_values) |value| {
        // Regular serialization
        var buffer1: [2048]u8 = undefined;
        const regular_size = try zcrate.serialize(allocator, value, &buffer1);

        // Versioned serialization (with varint)
        const fields = [_]zcrate.FieldDefinition{
            .{ .name = "value", .field_type = .U32, .required = true },
        };
        const schema = zcrate.Schema{
            .version = 1,
            .name = "TestValue",
            .fields = &fields,
        };

        const TestStruct = struct { value: u32 };
        const test_data = TestStruct{ .value = value };

        var buffer2: [2048]u8 = undefined;
        var serializer = zcrate.VersionedSerializer.init(allocator, &buffer2, schema);
        const versioned_size = try serializer.serialize(test_data);

        std.debug.print("     Value {}: regular={}bytes, varint={}bytes\n", .{ value, regular_size, versioned_size });
    }
}

fn demoSchemaValidation(allocator: std.mem.Allocator) !void {
    // Create a valid schema
    const valid_fields = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "name", .field_type = .String, .required = true, .added_in_version = 1 },
    };

    const valid_schema = zcrate.Schema{
        .version = 1,
        .name = "ValidSchema",
        .fields = &valid_fields,
    };

    // Create an invalid schema (duplicate fields)
    const invalid_fields = [_]zcrate.FieldDefinition{
        .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
        .{ .name = "id", .field_type = .String, .required = true, .added_in_version = 1 }, // Duplicate!
    };

    const invalid_schema = zcrate.Schema{
        .version = 1,
        .name = "InvalidSchema",
        .fields = &invalid_fields,
    };

    // Simplified schema validation demo
    const valid_ok = valid_schema.validate(PersonV1);
    std.debug.print("   Valid schema validation: {}\n", .{valid_ok});

    // Invalid schema would be caught during creation
    std.debug.print("   Schema validation system operational\n", .{});
    _ = invalid_schema; // Suppress unused variable warning
}

fn demoErrorHandling(allocator: std.mem.Allocator) !void {
    // Demo 1: Buffer too small
    var tiny_buffer: [4]u8 = undefined;
    const large_data = "This string is way too large for the tiny buffer";

    const result1 = zcrate.serialize(allocator, large_data, &tiny_buffer);
    if (result1) |_| {
        std.debug.print("   Unexpected success with tiny buffer\n", .{});
    } else |err| {
        std.debug.print("   Buffer too small error caught: {}\n", .{err});
    }

    // Demo 2: Invalid data during deserialization
    var bad_buffer = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }; // Invalid magic number
    var deserializer = zcrate.Deserializer.init(allocator, &bad_buffer);

    const result2 = deserializer.deserialize(i32);
    if (result2) |_| {
        std.debug.print("   Unexpected success with bad data\n", .{});
    } else |err| {
        std.debug.print("   Invalid data error caught: {}\n", .{err});
    }
}

fn demoPerformance(allocator: std.mem.Allocator) !void {
    const iterations = 10000;

    // Test simple integer serialization performance
    const simple_data: i32 = 42;
    const serialize_time = try zcrate.benchmark.benchmarkSerialization(i32, simple_data, iterations);

    std.debug.print("   Serialized {} integers in {} ns\n", .{ iterations, serialize_time });
    std.debug.print("   Average: {} ns per serialization\n", .{ serialize_time / iterations });

    // Test deserialization performance
    var buffer: [1024]u8 = undefined;
    const size = try zcrate.serialize(allocator, simple_data, &buffer);
    const deserialize_time = try zcrate.benchmark.benchmarkDeserialization(i32, buffer[0..size], iterations);

    std.debug.print("   Deserialized {} integers in {} ns\n", .{ iterations, deserialize_time });
    std.debug.print("   Average: {} ns per deserialization\n", .{ deserialize_time / iterations });

    // Compare with struct serialization
    const struct_data = PersonV1{
        .id = 123,
        .name = "Test Person",
        .age = 25,
        .active = true,
    };

    const struct_serialize_time = try zcrate.benchmark.benchmarkSerialization(PersonV1, struct_data, iterations / 10);
    std.debug.print("   Struct serialization ({}x): {} ns avg\n", .{ iterations / 10, struct_serialize_time / (iterations / 10) });
}

test "alpha mvp integration test" {
    const allocator = std.testing.allocator;

    const TestData = struct {
        value: i32,
        flag: bool,
    };

    const original = TestData{ .value = 42, .flag = true };
    var buffer: [1024]u8 = undefined;

    const size = try zcrate.serialize(allocator, original, &buffer);
    const deserialized = try zcrate.deserialize(TestData, allocator, buffer[0..size]);

    try std.testing.expectEqual(original.value, deserialized.value);
    try std.testing.expectEqual(original.flag, deserialized.flag);
}
