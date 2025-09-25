# ZCrate Basic Usage Examples

## Simple Data Types

### Integer Serialization
```zig
const std = @import("std");
const zcrate = @import("zcrate");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const value: i32 = 42;
    var buffer: [1024]u8 = undefined;

    // Serialize
    const size = try zcrate.serialize(allocator, value, &buffer);

    // Deserialize
    const result = try zcrate.deserialize(i32, allocator, buffer[0..size]);

    std.debug.print("Original: {}, Deserialized: {}\n", .{value, result});
}
```

### String Serialization
```zig
const message = "Hello, ZCrate!";
var buffer: [1024]u8 = undefined;

const size = try zcrate.serialize(allocator, message, &buffer);
const result = try zcrate.deserialize([]const u8, allocator, buffer[0..size]);

std.debug.print("Message: '{s}'\n", .{result});
```

## Struct Serialization

```zig
const Person = struct {
    id: u32,
    name: []const u8,
    age: u16,
    active: bool,
};

const person = Person{
    .id = 1001,
    .name = "Alice",
    .age = 28,
    .active = true,
};

var buffer: [1024]u8 = undefined;
const size = try zcrate.serialize(allocator, person, &buffer);
const result = try zcrate.deserialize(Person, allocator, buffer[0..size]);
```

## Schema Validation

```zig
const schema = zcrate.Schema.createSchema(Person, "Person", 1);
const is_valid = schema.validate(Person);

if (is_valid) {
    std.debug.print("Schema is valid!\n");
} else {
    std.debug.print("Schema validation failed!\n");
}
```

## Error Handling

```zig
const result = zcrate.serialize(allocator, data, buffer) catch |err| switch (err) {
    zcrate.SerializationError.BufferTooSmall => {
        std.debug.print("Buffer too small for serialization\n");
        return;
    },
    zcrate.SerializationError.UnsupportedType => {
        std.debug.print("Type not supported for serialization\n");
        return;
    },
    else => return err,
};
```