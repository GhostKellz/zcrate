//! ZCrate - High-performance serialization library for Zig
//! Provides efficient data packaging with schema evolution support

const std = @import("std");

pub const Serializer = @import("serializer.zig").Serializer;
pub const Deserializer = @import("deserializer.zig").Deserializer;
pub const VersionedSerializer = @import("versioned_serializer.zig").VersionedSerializer;
pub const VersionedDeserializer = @import("versioned_deserializer.zig").VersionedDeserializer;
pub const Schema = @import("schema.zig").Schema;
pub const FieldDefinition = @import("schema.zig").FieldDefinition;
pub const createSchema = @import("schema.zig").createSchema;
pub const types = @import("types.zig");
pub const benchmark = @import("benchmark.zig");

// Zero-copy functionality
pub const ZeroCopyView = @import("zero_copy.zig").ZeroCopyView;
pub const ZeroCopyData = @import("zero_copy.zig").ZeroCopyData;
pub const ZeroCopyResult = @import("zero_copy.zig").ZeroCopyResult;
pub const MappedFileReader = @import("zero_copy.zig").MappedFileReader;

// Schema validation
pub const SchemaValidator = @import("schema_validator.zig").SchemaValidator;
pub const ValidationResult = @import("schema_validator.zig").ValidationResult;

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

pub const ErrorContext = struct {
    error_code: SerializationError,
    message: []const u8,
    field_name: ?[]const u8 = null,
    position: ?usize = null,
    expected_type: ?[]const u8 = null,
    actual_type: ?[]const u8 = null,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("SerializationError.{s}: {s}", .{ @tagName(self.error_code), self.message });

        if (self.field_name) |field| {
            try writer.print(" (field: {s})", .{field});
        }

        if (self.position) |pos| {
            try writer.print(" at position {}", .{pos});
        }

        if (self.expected_type) |expected| {
            try writer.print(" (expected: {s}", .{expected});
            if (self.actual_type) |actual| {
                try writer.print(", got: {s}", .{actual});
            }
            try writer.print(")", .{});
        }
    }
};

pub fn serialize(allocator: std.mem.Allocator, data: anytype, buffer: []u8) !usize {
    var serializer = Serializer.init(allocator, buffer);
    return serializer.serialize(data);
}

pub fn deserialize(comptime T: type, allocator: std.mem.Allocator, buffer: []const u8) !T {
    var deserializer = Deserializer.init(allocator, buffer);
    return deserializer.deserialize(T);
}

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("ZCrate serialization library initialized.\n", .{});
    try stdout.flush();
}

test "basic serialization roundtrip" {
    const allocator = std.testing.allocator;

    const value: i32 = 42;
    var buffer: [1024]u8 = undefined;

    const serialized_size = try serialize(allocator, value, &buffer);
    const deserialized = try deserialize(i32, allocator, buffer[0..serialized_size]);

    try std.testing.expectEqual(value, deserialized);
}
