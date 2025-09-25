//! Zero-copy deserialization implementation

const std = @import("std");
const types = @import("types.zig");
const SerializationError = @import("root.zig").SerializationError;

/// Zero-copy view into serialized data
pub const ZeroCopyView = struct {
    buffer: []const u8,
    position: usize,

    pub fn init(buffer: []const u8) ZeroCopyView {
        return ZeroCopyView{
            .buffer = buffer,
            .position = 0,
        };
    }

    /// Get a view of the data without copying
    pub fn view(self: *ZeroCopyView, comptime T: type) !ZeroCopyData(T) {
        const start_pos = self.position;

        // Validate header
        try self.validateHeader(T);

        // Create view pointing to the data section
        return ZeroCopyData(T){
            .buffer = self.buffer,
            .data_start = self.position,
            .header_start = start_pos,
        };
    }

    fn validateHeader(self: *ZeroCopyView, comptime T: type) !void {
        const magic = try self.readU32();
        if (magic != 0x5A435254) return SerializationError.InvalidData;

        const version = try self.readU16();
        if (version != 1 and version != 2) return SerializationError.UnsupportedType;

        const type_tag: types.TypeTag = @enumFromInt(try self.readU8());
        const expected_tag = types.getTypeTag(T);
        if (type_tag != expected_tag) return SerializationError.InvalidData;

        // Skip remaining header fields for version 2
        if (version == 2) {
            _ = try self.readU32(); // schema version
            _ = try self.readU32(); // fingerprint
        }

        _ = try self.readU32(); // data size
    }

    fn readU32(self: *ZeroCopyView) !u32 {
        if (self.position + 4 > self.buffer.len) return SerializationError.InvalidData;
        const result = std.mem.readInt(u32, self.buffer[self.position..self.position + 4], .little);
        self.position += 4;
        return result;
    }

    fn readU16(self: *ZeroCopyView) !u16 {
        if (self.position + 2 > self.buffer.len) return SerializationError.InvalidData;
        const result = std.mem.readInt(u16, self.buffer[self.position..self.position + 2], .little);
        self.position += 2;
        return result;
    }

    fn readU8(self: *ZeroCopyView) !u8 {
        if (self.position >= self.buffer.len) return SerializationError.InvalidData;
        const result = self.buffer[self.position];
        self.position += 1;
        return result;
    }
};

/// Zero-copy data accessor
pub fn ZeroCopyData(comptime T: type) type {
    return struct {
        buffer: []const u8,
        data_start: usize,
        header_start: usize,

        const Self = @This();

        /// Access the data without copying (where possible)
        pub fn get(self: Self) !ZeroCopyResult(T) {
            var pos = self.data_start;
            return try self.getData(T, &pos);
        }

        /// Get a field from a struct by name (zero-copy where possible)
        pub fn getField(self: Self, comptime field_name: []const u8, comptime FieldT: type) !ZeroCopyResult(FieldT) {
            if (@typeInfo(T) != .@"struct") {
                @compileError("getField can only be called on struct types");
            }

            var pos = self.data_start;
            const struct_info = @typeInfo(T).@"struct";

            inline for (struct_info.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    return try self.getData(FieldT, &pos);
                } else {
                    // Skip this field
                    try self.skipData(field.type, &pos);
                }
            }

            return SerializationError.InvalidData; // Field not found
        }

        fn getData(self: Self, comptime DataT: type, pos: *usize) !ZeroCopyResult(DataT) {
            switch (@typeInfo(DataT)) {
                .int => {
                    const size = @sizeOf(DataT);
                    if (pos.* + size > self.buffer.len) return SerializationError.InvalidData;

                    const value = std.mem.bytesToValue(DataT, self.buffer[pos.*..pos.* + size][0..size]);
                    pos.* += size;

                    return ZeroCopyResult(DataT){ .owned = value };
                },
                .float => {
                    const size = @sizeOf(DataT);
                    if (pos.* + size > self.buffer.len) return SerializationError.InvalidData;

                    const value = std.mem.bytesToValue(DataT, self.buffer[pos.*..pos.* + size][0..size]);
                    pos.* += size;

                    return ZeroCopyResult(DataT){ .owned = value };
                },
                .bool => {
                    if (pos.* >= self.buffer.len) return SerializationError.InvalidData;

                    const value = self.buffer[pos.*] != 0;
                    pos.* += 1;

                    return ZeroCopyResult(DataT){ .owned = value };
                },
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        // String - can be zero-copy!
                        const len_bytes = self.buffer[pos.*..pos.* + 4];
                        const len = std.mem.readInt(u32, len_bytes[0..4], .little);
                        pos.* += 4;

                        if (pos.* + len > self.buffer.len) return SerializationError.InvalidData;

                        const str_view = self.buffer[pos.*..pos.* + len];
                        pos.* += len;

                        return ZeroCopyResult(DataT){ .view = str_view };
                    } else {
                        return SerializationError.UnsupportedType;
                    }
                },
                .@"struct" => {
                    // For structs, we need to recursively parse but can still provide zero-copy views for strings
                    const struct_info = @typeInfo(DataT).@"struct";
                    var result: DataT = undefined;

                    inline for (struct_info.fields) |field| {
                        const field_result = try self.getData(field.type, pos);
                        @field(result, field.name) = try field_result.getValue();
                    }

                    return ZeroCopyResult(DataT){ .owned = result };
                },
                .array => |array_info| {
                    // Skip array length
                    pos.* += 4;

                    var result: DataT = undefined;
                    for (&result) |*item| {
                        const item_result = try self.getData(array_info.child, pos);
                        item.* = try item_result.getValue();
                    }

                    return ZeroCopyResult(DataT){ .owned = result };
                },
                else => {
                    return SerializationError.UnsupportedType;
                },
            }
        }

        fn skipData(self: Self, comptime DataT: type, pos: *usize) !void {
            switch (@typeInfo(DataT)) {
                .int, .float => {
                    pos.* += @sizeOf(DataT);
                },
                .bool => {
                    pos.* += 1;
                },
                .pointer => |ptr_info| {
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        const len = std.mem.readInt(u32, self.buffer[pos.*..pos.* + 4][0..4], .little);
                        pos.* += 4 + len;
                    } else {
                        return SerializationError.UnsupportedType;
                    }
                },
                .@"struct" => |struct_info| {
                    inline for (struct_info.fields) |field| {
                        try self.skipData(field.type, pos);
                    }
                },
                .array => |array_info| {
                    const len = std.mem.readInt(u32, self.buffer[pos.*..pos.* + 4][0..4], .little);
                    pos.* += 4;

                    for (0..len) |_| {
                        try self.skipData(array_info.child, pos);
                    }
                },
                else => {
                    return SerializationError.UnsupportedType;
                },
            }
        }
    };
}

/// Result that may contain either a zero-copy view or owned data
pub fn ZeroCopyResult(comptime T: type) type {
    return union(enum) {
        view: []const u8,  // Zero-copy view (for strings, byte arrays)
        owned: T,          // Owned data (for numbers, structs)

        pub fn getValue(self: @This()) !T {
            return switch (self) {
                .owned => |value| value,
                .view => |bytes| {
                    // For string types, return the view directly
                    if (T == []const u8) {
                        return @as(T, bytes);
                    } else {
                        return SerializationError.UnsupportedType;
                    }
                },
            };
        }

        pub fn isZeroCopy(self: @This()) bool {
            return switch (self) {
                .view => true,
                .owned => false,
            };
        }
    };
}

/// Memory-mapped file reader for large datasets
pub const MappedFileReader = struct {
    file: std.fs.File,
    mapping: []align(std.mem.page_size) const u8,

    pub fn init(file_path: []const u8) !MappedFileReader {
        const file = try std.fs.cwd().openFile(file_path, .{});
        const file_size = try file.getEndPos();

        const mapping = try std.os.mmap(
            null,
            file_size,
            std.os.PROT.READ,
            std.os.MAP.PRIVATE,
            file.handle,
            0,
        );

        return MappedFileReader{
            .file = file,
            .mapping = mapping,
        };
    }

    pub fn deinit(self: *MappedFileReader) void {
        std.os.munmap(self.mapping);
        self.file.close();
    }

    pub fn getView(self: MappedFileReader, comptime T: type) !ZeroCopyData(T) {
        var view = ZeroCopyView.init(self.mapping);
        return try view.view(T);
    }

    pub fn getMultipleViews(self: MappedFileReader, comptime T: type) !MappedIterator(T) {
        return MappedIterator(T){
            .buffer = self.mapping,
            .position = 0,
        };
    }
};

/// Iterator over multiple serialized objects in a memory-mapped file
pub fn MappedIterator(comptime T: type) type {
    return struct {
        buffer: []const u8,
        position: usize,

        const Self = @This();

        pub fn next(self: *Self) !?ZeroCopyData(T) {
            if (self.position >= self.buffer.len) return null;

            var view = ZeroCopyView{
                .buffer = self.buffer[self.position..],
                .position = 0,
            };

            const data_view = try view.view(T);

            // Update position for next iteration
            self.position += view.position;

            return ZeroCopyData(T){
                .buffer = self.buffer[self.position - view.position..],
                .data_start = data_view.data_start,
                .header_start = data_view.header_start,
            };
        }
    };
}

test "zero-copy string access" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Create a serialized buffer with a string
    var buffer: [1024]u8 = undefined;
    var pos: usize = 0;

    // Write header manually
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(u32, 0x5A435254))); // magic
    pos += 4;
    @memcpy(buffer[pos..pos+2], &std.mem.toBytes(@as(u16, 1))); // version
    pos += 2;
    buffer[pos] = @intFromEnum(types.TypeTag.String); // type_tag
    pos += 1;
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(u32, 13))); // data_size
    pos += 4;

    // Write string data
    @memcpy(buffer[pos..pos+4], &std.mem.toBytes(@as(u32, 13))); // length
    pos += 4;
    @memcpy(buffer[pos..pos+13], "Hello, World!");
    pos += 13;

    var view = ZeroCopyView.init(buffer[0..pos]);
    const data_view = try view.view([]const u8);
    const result = try data_view.get();

    try std.testing.expect(result.isZeroCopy());
    const str = try result.getValue();
    try std.testing.expectEqualStrings("Hello, World!", str);
}

test "zero-copy struct field access" {
    _ = struct {
        id: u32,
        name: []const u8,
    };

    // This test would be implemented with actual serialized data
    // For now, it's a placeholder showing the API
}