# ZCrate API Reference - RC1

## Core Serialization API

### Basic Serialization
```zig
pub fn serialize(allocator: std.mem.Allocator, data: anytype, buffer: []u8) !usize
```
Simple serialization for basic use cases.

### Basic Deserialization
```zig
pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, buffer: []const u8) !T
```
Simple deserialization for basic use cases.

## Advanced Serialization API

### Versioned Serialization
```zig
pub const VersionedSerializer = struct {
    pub fn init(allocator: std.mem.Allocator, buffer: []u8, schema: Schema) VersionedSerializer
    pub fn serialize(self: *VersionedSerializer, data: anytype) !usize
}
```
Schema-aware serialization with evolution support.

### Versioned Deserialization
```zig
pub const VersionedDeserializer = struct {
    pub fn init(allocator: std.mem.Allocator, buffer: []const u8, schema: Schema) VersionedDeserializer
    pub fn deserialize(self: *VersionedDeserializer, comptime T: type) !T
}
```
Schema-aware deserialization with backward compatibility.

## Zero-Copy API

### Zero-Copy View
```zig
pub const ZeroCopyView = struct {
    pub fn init(buffer: []const u8) ZeroCopyView
    pub fn view(self: *ZeroCopyView, comptime T: type) !ZeroCopyData(T)
}
```
Create a zero-copy view of serialized data.

### Zero-Copy Data Access
```zig
pub fn ZeroCopyData(comptime T: type) type
    pub fn get(self: Self) !ZeroCopyResult(T)
    pub fn getField(self: Self, comptime field_name: []const u8, comptime FieldT: type) !ZeroCopyResult(FieldT)
```
Access data without copying when possible.

### Memory-Mapped Files
```zig
pub const MappedFileReader = struct {
    pub fn init(file_path: []const u8) !MappedFileReader
    pub fn deinit(self: *MappedFileReader) void
    pub fn getView(self: MappedFileReader, comptime T: type) !ZeroCopyData(T)
}
```
Efficient handling of large files through memory mapping.

## Schema System

### Schema Definition
```zig
pub const Schema = struct {
    version: u32,
    name: []const u8,
    fields: []const FieldDefinition,

    pub fn validate(self: Schema, comptime T: type) bool
    pub fn isCompatibleWith(self: Schema, other: Schema) bool
    pub fn findField(self: Schema, name: []const u8) ?FieldDefinition
}
```

### Field Definition
```zig
pub const FieldDefinition = struct {
    name: []const u8,
    field_type: FieldType,
    required: bool = true,
    default_value: ?[]const u8 = null,
    added_in_version: u32 = 1,
    removed_in_version: ?u32 = null,

    pub fn isActiveInVersion(self: FieldDefinition, version: u32) bool
    pub fn hasDefault(self: FieldDefinition) bool
}
```

### Schema Validation
```zig
pub const SchemaValidator = struct {
    pub fn init(allocator: std.mem.Allocator) SchemaValidator
    pub fn validateSchema(self: SchemaValidator, schema: Schema) !ValidationResult
    pub fn validateCompatibility(self: SchemaValidator, old_schema: Schema, new_schema: Schema) !ValidationResult
}
```

## Error Handling

### Comprehensive Error Types
```zig
pub const SerializationError = error{
    // Schema-related errors
    InvalidSchema,
    SchemaVersionMismatch,
    SchemaEvolutionError,
    IncompatibleSchema,

    // Data integrity errors
    InvalidData,
    InvalidMagicNumber,
    CorruptedData,
    ChecksumMismatch,

    // Type-related errors
    UnsupportedType,
    TypeMismatch,
    InvalidTypeTag,

    // Buffer and memory errors
    BufferTooSmall,
    OutOfMemory,
    EndOfBuffer,

    // Field-related errors
    RequiredFieldMissing,
    UnknownField,
    FieldTypeMismatch,

    // File I/O errors
    FileNotFound,
    FileReadError,
    FileWriteError,
    MappingFailed,

    // Version-related errors
    UnsupportedFormatVersion,
    BackwardCompatibilityError,
    ForwardCompatibilityError,
};
```

### Error Context
```zig
pub const ErrorContext = struct {
    error_code: SerializationError,
    message: []const u8,
    field_name: ?[]const u8 = null,
    position: ?usize = null,
    expected_type: ?[]const u8 = null,
    actual_type: ?[]const u8 = null,
}
```

## Performance API

### Benchmarking
```zig
pub const benchmark = struct {
    pub fn benchmarkSerialization(comptime T: type, data: T, iterations: usize) !u64
    pub fn benchmarkDeserialization(comptime T: type, buffer: []const u8, iterations: usize) !u64
}
```

## Data Format Evolution

### Version 1 Format (Alpha)
```
Header (11 bytes):
- Magic: "ZCRT" (4 bytes)
- Version: u16 = 1 (2 bytes)
- Type Tag: u8 (1 byte)
- Data Size: u32 (4 bytes)

Data: Variable length binary content
```

### Version 2 Format (Beta+)
```
Header (19 bytes):
- Magic: "ZCRT" (4 bytes)
- Version: u16 = 2 (2 bytes)
- Type Tag: u8 (1 byte)
- Schema Version: u32 (4 bytes)
- Schema Fingerprint: u32 (4 bytes)
- Data Size: u32 (4 bytes)

Struct Data:
- Field Count: u32 (4 bytes)
- For each field:
  - Name Length: u16 (2 bytes)
  - Field Name: Variable length
  - Field Type: u8 (1 byte)
  - Field Data: Variable length (using varint encoding where applicable)
```

## Type System

### Supported Types
- **Primitive Types**: All integer types, floats, booleans
- **Composite Types**: Structs, arrays, slices
- **String Types**: UTF-8 strings with zero-copy support
- **Optional Types**: Fields with default values
- **Nested Types**: Recursive struct serialization

### Type Safety Features
- **Compile-time validation**: Type checking at compile time
- **Runtime validation**: Data integrity checks during deserialization
- **Schema enforcement**: Ensure data matches expected schema
- **Version compatibility**: Safe evolution across schema versions

## Usage Patterns

### Basic Usage
```zig
const person = Person{ .id = 1, .name = "Alice" };
var buffer: [1024]u8 = undefined;

const size = try zcrate.serialize(allocator, person, &buffer);
const result = try zcrate.deserialize(Person, allocator, buffer[0..size]);
```

### Schema-Aware Usage
```zig
const schema = zcrate.Schema{ .version = 1, .name = "Person", .fields = &fields };
var serializer = zcrate.VersionedSerializer.init(allocator, &buffer, schema);
const size = try serializer.serialize(person);

var deserializer = zcrate.VersionedDeserializer.init(allocator, buffer[0..size], schema);
const result = try deserializer.deserialize(Person);
```

### Zero-Copy Usage
```zig
var view = zcrate.ZeroCopyView.init(buffer);
const data_view = try view.view(Person);
const name_result = try data_view.getField("name", []const u8);

if (name_result.isZeroCopy()) {
    const name = try name_result.getValue(); // Direct pointer, no copying
    std.debug.print("Name: {s}\n", .{name});
}
```

### Memory-Mapped File Usage
```zig
var mapped_reader = try zcrate.MappedFileReader.init("large_data.zcrate");
defer mapped_reader.deinit();

const data_view = try mapped_reader.getView(Person);
const person = try data_view.get();
```