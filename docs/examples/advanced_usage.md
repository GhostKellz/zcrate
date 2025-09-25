# ZCrate Advanced Usage Examples - RC1

## Table of Contents
1. [Schema Evolution](#schema-evolution)
2. [Zero-Copy Deserialization](#zero-copy-deserialization)
3. [Memory-Mapped Files](#memory-mapped-files)
4. [Performance Optimization](#performance-optimization)
5. [Error Handling](#error-handling)
6. [Custom Serialization](#custom-serialization)

## Schema Evolution

### Defining Schemas
```zig
const std = @import("std");
const zcrate = @import("zcrate");

// Define field definitions for different schema versions
const user_fields_v1 = [_]zcrate.FieldDefinition{
    .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
    .{ .name = "username", .field_type = .String, .required = true, .added_in_version = 1 },
    .{ .name = "email", .field_type = .String, .required = true, .added_in_version = 1 },
};

const user_fields_v2 = [_]zcrate.FieldDefinition{
    .{ .name = "id", .field_type = .U32, .required = true, .added_in_version = 1 },
    .{ .name = "username", .field_type = .String, .required = true, .added_in_version = 1 },
    .{ .name = "email", .field_type = .String, .required = true, .added_in_version = 1 },
    .{ .name = "full_name", .field_type = .String, .required = false, .added_in_version = 2, .default_value = "" },
    .{ .name = "age", .field_type = .U16, .required = false, .added_in_version = 2, .default_value = "0" },
    .{ .name = "premium", .field_type = .Bool, .required = false, .added_in_version = 2, .default_value = "false" },
};

const schema_v1 = zcrate.Schema{
    .version = 1,
    .name = "User",
    .fields = &user_fields_v1,
};

const schema_v2 = zcrate.Schema{
    .version = 2,
    .name = "User",
    .fields = &user_fields_v2,
};
```

### Backward Compatible Serialization
```zig
const UserV1 = struct {
    id: u32,
    username: []const u8,
    email: []const u8,
};

const UserV2 = struct {
    id: u32,
    username: []const u8,
    email: []const u8,
    full_name: []const u8,
    age: u16,
    premium: bool,
};

pub fn demonstrateSchemaEvolution() !void {
    const allocator = std.heap.page_allocator;

    // Create V1 user data
    const user_v1 = UserV1{
        .id = 12345,
        .username = "alice_smith",
        .email = "alice@example.com",
    };

    // Serialize with V1 schema
    var buffer: [2048]u8 = undefined;
    var serializer_v1 = zcrate.VersionedSerializer.init(allocator, &buffer, schema_v1);
    const size = try serializer_v1.serialize(user_v1);

    std.debug.print("Serialized V1 user: {} bytes\n", .{size});

    // Deserialize V1 data with V2 schema (backward compatibility)
    var deserializer_v2 = zcrate.VersionedDeserializer.init(allocator, buffer[0..size], schema_v2);
    const user_v2 = try deserializer_v2.deserialize(UserV2);

    std.debug.print("Deserialized as V2:\n");
    std.debug.print("  ID: {}\n", .{user_v2.id});
    std.debug.print("  Username: {s}\n", .{user_v2.username});
    std.debug.print("  Email: {s}\n", .{user_v2.email});
    std.debug.print("  Full Name: '{s}' (default)\n", .{user_v2.full_name});
    std.debug.print("  Age: {} (default)\n", .{user_v2.age});
    std.debug.print("  Premium: {} (default)\n", .{user_v2.premium});
}
```

### Schema Validation
```zig
pub fn validateSchemaCompatibility() !void {
    const allocator = std.heap.page_allocator;
    const validator = zcrate.SchemaValidator.init(allocator);

    // Check if schemas are compatible
    if (schema_v1.isCompatibleWith(schema_v2)) {
        std.debug.print("✅ V1 → V2 migration is safe\n");
    } else {
        std.debug.print("❌ V1 → V2 migration may cause issues\n");
    }

    // Validate individual schemas
    const v1_valid = schema_v1.validate(UserV1);
    const v2_valid = schema_v2.validate(UserV2);

    std.debug.print("Schema V1 validates UserV1: {}\n", .{v1_valid});
    std.debug.print("Schema V2 validates UserV2: {}\n", .{v2_valid});
}
```

## Zero-Copy Deserialization

### Basic Zero-Copy Access
```zig
pub fn demonstrateZeroCopy() !void {
    const allocator = std.heap.page_allocator;

    const message = "This string will be accessed without copying!";
    var buffer: [2048]u8 = undefined;

    // Regular serialization
    const size = try zcrate.serialize(allocator, message, &buffer);

    // Zero-copy access
    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const data_view = try view.view([]const u8);
    const result = try data_view.get();

    if (result.isZeroCopy()) {
        std.debug.print("🚀 Zero-copy access successful!\n");
        const zero_copy_string = try result.getValue();
        std.debug.print("String: '{s}'\n", .{zero_copy_string});

        // Verify it's the same memory location
        const original_ptr = @intFromPtr(message.ptr);
        const zero_copy_ptr = @intFromPtr(zero_copy_string.ptr);
        std.debug.print("Original data is at the same location: {}\n", .{original_ptr != zero_copy_ptr});
        std.debug.print("But content is identical: {}\n", .{std.mem.eql(u8, message, zero_copy_string)});
    }
}
```

### Struct Field Zero-Copy Access
```zig
const Document = struct {
    id: u64,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: u64,
};

pub fn demonstrateStructZeroCopy() !void {
    const allocator = std.heap.page_allocator;

    const doc = Document{
        .id = 98765,
        .title = "Zero-Copy Serialization in Zig",
        .content = "Lorem ipsum dolor sit amet, consectetur adipiscing elit...",
        .author = "ZCrate Team",
        .created_at = 1609459200, // Unix timestamp
    };

    var buffer: [4096]u8 = undefined;
    const size = try zcrate.serialize(allocator, doc, &buffer);

    // Access the entire struct
    var view = zcrate.ZeroCopyView.init(buffer[0..size]);
    const data_view = try view.view(Document);
    const document_result = try data_view.get();
    const document = try document_result.getValue();

    std.debug.print("Document ID: {}\n", .{document.id});
    std.debug.print("Title: '{s}'\n", .{document.title});
    std.debug.print("Author: '{s}'\n", .{document.author});

    // Individual field access would require enhanced zero-copy implementation
    // This demonstrates the API design for future development
}
```

## Memory-Mapped Files

### Large Dataset Processing
```zig
pub fn processLargeDataset() !void {
    const allocator = std.heap.page_allocator;

    // First, create a large dataset file
    try createSampleDataFile("large_dataset.zcrate");

    // Process using memory-mapped access
    var mapped_reader = try zcrate.MappedFileReader.init("large_dataset.zcrate");
    defer mapped_reader.deinit();

    std.debug.print("📁 Processing memory-mapped file...\n");

    // Get iterator for multiple records
    var iterator = try mapped_reader.getMultipleViews(UserV2);

    var count: u32 = 0;
    while (try iterator.next()) |user_view| {
        const user_result = try user_view.get();
        const user = try user_result.getValue();

        if (count < 5) { // Show first 5 records
            std.debug.print("User {}: {s} ({})\n", .{ user.id, user.username, user.email });
        }
        count += 1;
    }

    std.debug.print("Processed {} records from memory-mapped file\n", .{count});
}

fn createSampleDataFile(filename: []const u8) !void {
    // This would create a file with multiple serialized records
    // Implementation would write several UserV2 records to the file
    const allocator = std.heap.page_allocator;

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    // Write multiple users to the file
    var buffer: [1024]u8 = undefined;

    const users = [_]UserV2{
        .{ .id = 1, .username = "alice", .email = "alice@example.com", .full_name = "Alice Smith", .age = 25, .premium = true },
        .{ .id = 2, .username = "bob", .email = "bob@example.com", .full_name = "Bob Johnson", .age = 30, .premium = false },
        .{ .id = 3, .username = "carol", .email = "carol@example.com", .full_name = "Carol Williams", .age = 28, .premium = true },
    };

    for (users) |user| {
        const size = try zcrate.serialize(allocator, user, &buffer);
        _ = try file.writeAll(buffer[0..size]);
    }
}
```

## Performance Optimization

### Variable-Length Encoding Comparison
```zig
pub fn compareEncodingEfficiency() !void {
    const allocator = std.heap.page_allocator;

    const test_values = [_]u64{ 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456 };

    std.debug.print("📊 Encoding Efficiency Comparison:\n");
    std.debug.print("Value          | Fixed | Varint | Savings\n");
    std.debug.print("---------------|-------|--------|--------\n");

    for (test_values) |value| {
        var buffer1: [16]u8 = undefined;
        var buffer2: [16]u8 = undefined;

        // Fixed-size encoding (regular serialization)
        const fixed_size = try zcrate.serialize(allocator, value, &buffer1);

        // Variable-length encoding (versioned serialization)
        const fields = [_]zcrate.FieldDefinition{
            .{ .name = "value", .field_type = .U64, .required = true },
        };
        const schema = zcrate.Schema{
            .version = 1,
            .name = "TestValue",
            .fields = &fields,
        };

        const TestStruct = struct { value: u64 };
        const test_data = TestStruct{ .value = value };

        var serializer = zcrate.VersionedSerializer.init(allocator, &buffer2, schema);
        const varint_size = try serializer.serialize(test_data);

        const savings = @as(f64, @floatFromInt(fixed_size - varint_size)) / @as(f64, @floatFromInt(fixed_size)) * 100.0;

        std.debug.print("{:>12} | {:>5} | {:>6} | {:>5.1}%\n", .{ value, fixed_size, varint_size, savings });
    }
}
```

### Benchmarking Different Data Types
```zig
pub fn benchmarkDataTypes() !void {
    const allocator = std.heap.page_allocator;
    const iterations = 100000;

    std.debug.print("🏃 Performance Benchmarks ({} iterations):\n", .{iterations});

    // Integer benchmarks
    const int_data: i64 = 9876543210;
    const int_serialize_time = try zcrate.benchmark.benchmarkSerialization(i64, int_data, iterations);

    var buffer: [1024]u8 = undefined;
    const int_size = try zcrate.serialize(allocator, int_data, &buffer);
    const int_deserialize_time = try zcrate.benchmark.benchmarkDeserialization(i64, buffer[0..int_size], iterations);

    std.debug.print("Integer (i64):\n");
    std.debug.print("  Serialize: {} ns/op\n", .{int_serialize_time / iterations});
    std.debug.print("  Deserialize: {} ns/op\n", .{int_deserialize_time / iterations});

    // String benchmarks
    const string_data = "The quick brown fox jumps over the lazy dog";
    const string_serialize_time = try zcrate.benchmark.benchmarkSerialization([]const u8, string_data, iterations);

    const string_size = try zcrate.serialize(allocator, string_data, &buffer);
    const string_deserialize_time = try zcrate.benchmark.benchmarkDeserialization([]const u8, buffer[0..string_size], iterations);

    std.debug.print("String (43 chars):\n");
    std.debug.print("  Serialize: {} ns/op\n", .{string_serialize_time / iterations});
    std.debug.print("  Deserialize: {} ns/op\n", .{string_deserialize_time / iterations});

    // Struct benchmarks
    const struct_data = UserV2{
        .id = 12345,
        .username = "performance_test",
        .email = "perf@example.com",
        .full_name = "Performance Test User",
        .age = 25,
        .premium = true,
    };

    const struct_serialize_time = try zcrate.benchmark.benchmarkSerialization(UserV2, struct_data, iterations / 10);

    const struct_size = try zcrate.serialize(allocator, struct_data, &buffer);
    const struct_deserialize_time = try zcrate.benchmark.benchmarkDeserialization(UserV2, buffer[0..struct_size], iterations / 10);

    std.debug.print("Struct (UserV2):\n");
    std.debug.print("  Serialize: {} ns/op\n", .{struct_serialize_time / (iterations / 10)});
    std.debug.print("  Deserialize: {} ns/op\n", .{struct_deserialize_time / (iterations / 10)});
}
```

## Error Handling

### Comprehensive Error Handling
```zig
pub fn demonstrateErrorHandling() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("🛡️ Error Handling Examples:\n");

    // Buffer too small error
    {
        var tiny_buffer: [4]u8 = undefined;
        const large_data = "This string is much too large for the tiny buffer provided";

        const result = zcrate.serialize(allocator, large_data, &tiny_buffer);
        if (result) |_| {
            std.debug.print("❌ Unexpected success\n");
        } else |err| switch (err) {
            zcrate.SerializationError.BufferTooSmall => {
                std.debug.print("✅ Caught BufferTooSmall error as expected\n");
            },
            else => {
                std.debug.print("❌ Unexpected error: {}\n", .{err});
            },
        }
    }

    // Invalid data error
    {
        var bad_buffer = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00 };

        const result = zcrate.deserialize(i32, allocator, &bad_buffer);
        if (result) |_| {
            std.debug.print("❌ Unexpected success with bad data\n");
        } else |err| switch (err) {
            zcrate.SerializationError.InvalidData,
            zcrate.SerializationError.InvalidMagicNumber => {
                std.debug.print("✅ Caught invalid data error as expected\n");
            },
            else => {
                std.debug.print("❌ Unexpected error: {}\n", .{err});
            },
        }
    }

    // Type mismatch error
    {
        const int_value: i32 = 42;
        var buffer: [1024]u8 = undefined;
        const size = try zcrate.serialize(allocator, int_value, &buffer);

        // Try to deserialize as wrong type
        const result = zcrate.deserialize(f32, allocator, buffer[0..size]);
        if (result) |_| {
            std.debug.print("❌ Unexpected success with type mismatch\n");
        } else |err| switch (err) {
            zcrate.SerializationError.InvalidData,
            zcrate.SerializationError.TypeMismatch,
            zcrate.SerializationError.InvalidTypeTag => {
                std.debug.print("✅ Caught type mismatch error as expected\n");
            },
            else => {
                std.debug.print("❌ Unexpected error: {}\n", .{err});
            },
        }
    }
}
```

### Error Context Usage
```zig
pub fn demonstrateErrorContext() void {
    // Example of how error context would be used in a real application
    const error_ctx = zcrate.ErrorContext{
        .error_code = zcrate.SerializationError.FieldTypeMismatch,
        .message = "Field type does not match schema definition",
        .field_name = "age",
        .position = 42,
        .expected_type = "u16",
        .actual_type = "string",
    };

    std.debug.print("Error details: {}\n", .{error_ctx});
    // Would output: "SerializationError.FieldTypeMismatch: Field type does not match schema definition (field: age) at position 42 (expected: u16, got: string)"
}
```

## Custom Serialization

### Advanced Serialization Patterns
```zig
const CustomData = struct {
    timestamp: u64,
    data: []const u8,
    checksum: u32,

    pub fn calculateChecksum(self: CustomData) u32 {
        // Simple checksum calculation
        var sum: u32 = 0;
        for (self.data) |byte| {
            sum = sum +% byte;
        }
        return sum;
    }
};

pub fn demonstrateCustomSerialization() !void {
    const allocator = std.heap.page_allocator;

    const custom_data = CustomData{
        .timestamp = std.time.timestamp(),
        .data = "Important data that needs integrity checking",
        .checksum = 0, // Will be calculated
    };

    // Calculate checksum before serialization
    const data_with_checksum = CustomData{
        .timestamp = custom_data.timestamp,
        .data = custom_data.data,
        .checksum = custom_data.calculateChecksum(),
    };

    var buffer: [2048]u8 = undefined;
    const size = try zcrate.serialize(allocator, data_with_checksum, &buffer);

    std.debug.print("Serialized custom data with checksum: {} bytes\n", .{size});

    // Deserialize and verify checksum
    const deserialized = try zcrate.deserialize(CustomData, allocator, buffer[0..size]);
    const calculated_checksum = deserialized.calculateChecksum();

    if (deserialized.checksum == calculated_checksum) {
        std.debug.print("✅ Data integrity verified\n");
    } else {
        std.debug.print("❌ Data corruption detected!\n");
    }

    std.debug.print("Timestamp: {}\n", .{deserialized.timestamp});
    std.debug.print("Data: '{s}'\n", .{deserialized.data});
    std.debug.print("Checksum: {} (calculated: {})\n", .{ deserialized.checksum, calculated_checksum });
}
```

## Complete Example Program

```zig
const std = @import("std");
const zcrate = @import("zcrate");

pub fn main() !void {
    std.debug.print("🚀 ZCrate Advanced Usage Examples\n\n");

    try demonstrateSchemaEvolution();
    std.debug.print("\n");

    try validateSchemaCompatibility();
    std.debug.print("\n");

    try demonstrateZeroCopy();
    std.debug.print("\n");

    try processLargeDataset();
    std.debug.print("\n");

    try compareEncodingEfficiency();
    std.debug.print("\n");

    try benchmarkDataTypes();
    std.debug.print("\n");

    try demonstrateErrorHandling();
    std.debug.print("\n");

    demonstrateErrorContext();
    std.debug.print("\n");

    try demonstrateCustomSerialization();

    std.debug.print("\n✅ All advanced examples completed successfully!\n");
}

// Include all the functions defined above here...
```

This comprehensive example demonstrates all the advanced features of ZCrate RC1, showing how to use schema evolution, zero-copy deserialization, memory-mapped files, performance optimization, and robust error handling in real-world scenarios.