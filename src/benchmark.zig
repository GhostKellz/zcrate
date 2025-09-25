//! Basic benchmarking utilities for ZCrate

const std = @import("std");
const zcrate = @import("root.zig");

pub fn benchmarkSerialization(comptime T: type, data: T, iterations: usize) !u64 {
    var buffer: [1024]u8 = undefined;
    const allocator = std.heap.page_allocator;

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        _ = try zcrate.serialize(allocator, data, &buffer);
    }

    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

pub fn benchmarkDeserialization(comptime T: type, buffer: []const u8, iterations: usize) !u64 {
    const allocator = std.heap.page_allocator;

    const start = std.time.nanoTimestamp();

    for (0..iterations) |_| {
        _ = try zcrate.deserialize(T, allocator, buffer);
    }

    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

test "basic benchmarking" {
    const iterations = 1000;
    const data: i32 = 42;

    const serialize_time = try benchmarkSerialization(i32, data, iterations);
    std.debug.print("Serialized {} i32s in {} ns (avg: {} ns/op)\n", .{ iterations, serialize_time, serialize_time / iterations });

    var buffer: [1024]u8 = undefined;
    const allocator = std.testing.allocator;
    const size = try zcrate.serialize(allocator, data, &buffer);

    const deserialize_time = try benchmarkDeserialization(i32, buffer[0..size], iterations);
    std.debug.print("Deserialized {} i32s in {} ns (avg: {} ns/op)\n", .{ iterations, deserialize_time, deserialize_time / iterations });
}