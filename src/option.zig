const std = @import("std");
const testing = std.testing;

/// Generic Option constructor function
pub fn Option(comptime T: type) type {
    return struct {
        const Self = @This();

        name: ?[]const u8 = null,
        short: ?u8 = null,
        description: []const u8,
        default_value: ?T = null,
        value: ?T = null,
        allocator: std.mem.Allocator,

        /// Initialize an option
        pub fn init(description: []const u8, allocator: std.mem.Allocator) !*Self {
            const option = try allocator.create(Self);
            option.* = Self{
                .description = description,
                .allocator = allocator,
            };
            return option;
        }

        /// Deinitialize the option and free its memory
        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        /// Set the long name for the option (e.g., "verbose")
        pub fn withName(self: *Self, name: []const u8) *Self {
            self.name = name;
            return self;
        }

        /// Set the short name for the option (e.g., 'v')
        pub fn withShort(self: *Self, short: u8) *Self {
            self.short = short;
            return self;
        }

        /// Set the default value for the option
        pub fn withDefault(self: *Self, default_value: T) *Self {
            self.default_value = default_value;
            return self;
        }

        /// Set the current value for the option
        pub fn withValue(self: *Self, value: T) *Self {
            self.value = value;
            return self;
        }

        /// Get the description of the option
        pub fn getDescription(self: *const Self) []const u8 {
            return self.description;
        }

        /// Get the default value as a string, returns null if no default is set
        pub fn getDefaultValueAsString(self: *const Self, allocator: std.mem.Allocator) !?[]u8 {
            if (self.default_value) |default| {
                return try valueToString(T, default, allocator);
            }
            return null;
        }
        /// Get the value of the option, returns default if not set, error if neither is available
        pub fn getValue(self: *const Self) !T {
            if (self.value) |v| {
                return v;
            }
            if (self.default_value) |d| {
                return d;
            }
            return error.NoValueSet;
        }

        /// Get the long name of the option
        pub fn getName(self: *const Self) ?[]const u8 {
            return self.name;
        }

        /// Get the short name of the option
        pub fn getShort(self: *const Self) ?u8 {
            return self.short;
        }

        /// Set the value of the option
        pub fn setValue(self: *Self, value: T) void {
            self.value = value;
        }
    };
}

/// Convert any typed value to its string representation
fn valueToString(comptime T: type, value: T, allocator: std.mem.Allocator) ![]u8 {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => try allocator.dupe(u8, if (value) "true" else "false"),
        .int => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8)
                try allocator.dupe(u8, value)
            else blk: {
                // Handle dynamic slices
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);

                for (value, 0..) |item, i| {
                    if (i > 0) try result.append(',');
                    const item_str = try valueToString(@TypeOf(item), item, allocator);
                    defer allocator.free(item_str);
                    try result.appendSlice(allocator, item_str);
                }
                break :blk try result.toOwnedSlice();
            },
            else => try allocator.dupe(u8, "?"),
        },
        .array => blk: {
            var result = std.ArrayList(u8).empty;
            defer result.deinit(allocator);

            for (value, 0..) |item, i| {
                if (i > 0) try result.append(',');
                const item_str = try valueToString(@TypeOf(item), item, allocator);
                defer allocator.free(item_str);
                try result.appendSlice(allocator, item_str);
            }
            break :blk try result.toOwnedSlice();
        },
        .@"enum" => blk: {
            // Convert enum to its field name
            const enum_info = type_info.@"enum";
            const int_value = @intFromEnum(value);

            inline for (enum_info.fields) |field| {
                if (field.value == int_value) {
                    break :blk try allocator.dupe(u8, field.name);
                }
            }

            // Fallback to numeric representation if field not found
            break :blk try std.fmt.allocPrint(allocator, "{d}", .{int_value});
        },
        .@"struct" => blk: {
            const json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch {
                break :blk try allocator.dupe(u8, "?");
            };
            break :blk json; // caller owns and must free
        },
        else => try allocator.dupe(u8, "?"),
    };
}

/// Parse an enum value from a string
fn parseEnum(comptime EnumType: type, str_value: []const u8) !EnumType {
    const type_info = @typeInfo(EnumType);
    if (type_info != .@"enum") {
        @compileError("parseEnum only works with enum types");
    }

    // Check each enum field name
    inline for (type_info.@"enum".fields) |field| {
        if (std.mem.eql(u8, str_value, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.InvalidEnumValue;
}

/// Parse a fixed-size array from a CSV string
fn parseFixedArray(comptime ArrayType: type, str_value: []const u8) !ArrayType {
    const type_info = @typeInfo(ArrayType);
    if (type_info != .array) {
        @compileError("parseFixedArray only works with array types");
    }

    const array_info = type_info.array;
    const ElementType = array_info.child;

    var result: ArrayType = undefined;
    var iterator = std.mem.splitScalar(u8, str_value, ',');
    var index: usize = 0;

    while (iterator.next()) |element_str| {
        if (index >= array_info.len) {
            return error.TooManyElements;
        }

        // Trim whitespace from each element
        const trimmed = std.mem.trim(u8, element_str, " \t\r\n");

        // Parse elements recursively using parseValueFromString
        result[index] = try parseValueFromString(ElementType, trimmed);
        index += 1;
    }

    if (index != array_info.len) {
        return error.NotEnoughElements;
    }

    return result;
}

/// Parse a dynamic slice from a CSV string
fn parseSlice(comptime SliceType: type, str_value: []const u8, allocator: std.mem.Allocator) !SliceType {
    const type_info = @typeInfo(SliceType);
    if (type_info != .pointer or type_info.pointer.size != .slice) {
        @compileError("parseSlice only works with slice types");
    }

    const ElementType = type_info.pointer.child;

    if (str_value.len == 0) {
        return try allocator.alloc(ElementType, 0);
    }

    var count: usize = 0;
    var count_iterator = std.mem.splitScalar(u8, str_value, ',');
    while (count_iterator.next() != null) {
        count += 1;
    }

    if (count == 0) {
        return try allocator.alloc(ElementType, 0);
    }

    const result = try allocator.alloc(ElementType, count);
    errdefer allocator.free(result);

    var iterator = std.mem.splitScalar(u8, str_value, ',');
    var index: usize = 0;

    while (iterator.next()) |element_str| {
        // Trim whitespace from each element
        const trimmed = std.mem.trim(u8, element_str, " \t\r\n");

        // Parse elements recursively using parseValueFromString
        result[index] = try parseValueFromString(ElementType, trimmed);
        index += 1;
    }

    return result;
}

/// Parse a JSON string into the specified struct type
fn parseStruct(comptime StructType: type, str_value: []const u8, allocator: std.mem.Allocator) !StructType {
    const type_info = @typeInfo(StructType);
    if (type_info != .@"struct") {
        @compileError("parseStruct only works with struct types");
    }

    // Parse JSON string into the struct
    const parsed = std.json.parseFromSlice(
        StructType,
        allocator,
        str_value,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.SyntaxError => return error.InvalidJsonFormat,
        error.UnexpectedToken => return error.InvalidJsonFormat,
        error.InvalidCharacter => return error.InvalidJsonFormat,
        error.UnexpectedEndOfInput => return error.InvalidJsonFormat,
        error.MissingField => return error.MissingRequiredField,
        error.UnknownField => return error.UnknownJsonField,
        else => return err,
    };
    defer parsed.deinit();

    return parsed.value;
}

/// Parse a string value into the specified type
pub fn parseValueFromString(comptime T: type, str_value: []const u8) !T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => std.mem.eql(u8, str_value, "true") or std.mem.eql(u8, str_value, "1"),
        .int => try std.fmt.parseInt(T, str_value, 10),
        .float => try std.fmt.parseFloat(T, str_value),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8)
                str_value
            else
                return error.UnsupportedSliceType, // Slices need allocator, use parseValueFromStringWithAllocator
            else => return error.UnsupportedPointerType,
        },
        .@"enum" => try parseEnum(T, str_value),
        .array => return error.UnsupportedArrayType, // Arrays need allocator, use parseValueFromStringWithAllocator
        else => return error.UnsupportedType,
    };
}

/// Parse a string value into the specified type with allocator support for dynamic types
pub fn parseValueFromStringWithAllocator(comptime T: type, str_value: []const u8, allocator: std.mem.Allocator) !T {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .bool => std.mem.eql(u8, str_value, "true") or std.mem.eql(u8, str_value, "1"),
        .int => try std.fmt.parseInt(T, str_value, 10),
        .float => try std.fmt.parseFloat(T, str_value),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .slice => if (ptr_info.child == u8)
                str_value
            else
                try parseSlice(T, str_value, allocator),
            else => return error.UnsupportedPointerType,
        },
        .@"enum" => try parseEnum(T, str_value),
        .array => try parseFixedArray(T, str_value),
        .@"struct" => try parseStruct(T, str_value, allocator),
        else => return error.UnsupportedType,
    };
}

/// Interface for type-erased option handling
pub const OptionInterface = struct {
    ptr: *anyopaque,
    vtable: *const OptionVTable,

    const Self = @This();

    const OptionVTable = struct {
        getDescription: *const fn (ptr: *anyopaque) []const u8,
        getDefaultValueAsString: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        getValueAsString: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
        setValueFromString: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
        hasValue: *const fn (ptr: *anyopaque) bool,
        getName: *const fn (ptr: *anyopaque) ?[]const u8,
        getShort: *const fn (ptr: *anyopaque) ?u8,
        getTypedValuePtr: *const fn (ptr: *anyopaque) anyerror!*anyopaque,
        type_info: TypeInfo,
    };

    const TypeInfo = struct {
        name: []const u8,
        hash: u64,

        pub fn create(comptime T: type) TypeInfo {
            const type_name = @typeName(T);
            return TypeInfo{
                .name = type_name,
                .hash = comptime std.hash_map.hashString(type_name),
            };
        }
    };

    /// Create an OptionInterface from a typed option
    pub fn init(comptime InnerType: type, option_ptr: *Option(InnerType)) Self {
        const T = @TypeOf(option_ptr.*);

        const Vtable = struct {
            const type_info = TypeInfo.create(InnerType);
            const vtable = OptionVTable{
                .getDescription = struct {
                    fn getDescription(ptr: *anyopaque) []const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getDescription();
                    }
                }.getDescription,
                .getDefaultValueAsString = struct {
                    fn getDefaultValueAsString(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getDefaultValueAsString(allocator);
                    }
                }.getDefaultValueAsString,
                .getValueAsString = struct {
                    fn getValueAsString(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        const value = try self.getValue();

                        return try valueToString(InnerType, value, allocator);
                    }
                }.getValueAsString,
                .setValueFromString = struct {
                    fn setValueFromString(ptr: *anyopaque, str_value: []const u8) anyerror!void {
                        const self: *T = @ptrCast(@alignCast(ptr));

                        const inner_type_info = @typeInfo(InnerType);
                        const needs_allocator = switch (inner_type_info) {
                            .array => true,
                            .pointer => |ptr_info| ptr_info.size == .slice and ptr_info.child != u8,
                            .@"struct" => true,
                            else => false,
                        };

                        const typed_value = if (needs_allocator)
                            try parseValueFromStringWithAllocator(InnerType, str_value, self.allocator)
                        else
                            try parseValueFromString(InnerType, str_value);

                        self.setValue(typed_value);
                    }
                }.setValueFromString,
                .hasValue = struct {
                    fn hasValue(ptr: *anyopaque) bool {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.value != null;
                    }
                }.hasValue,
                .getName = struct {
                    fn getName(ptr: *anyopaque) ?[]const u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getName();
                    }
                }.getName,
                .getShort = struct {
                    fn getShort(ptr: *anyopaque) ?u8 {
                        const self: *T = @ptrCast(@alignCast(ptr));
                        return self.getShort();
                    }
                }.getShort,
                .getTypedValuePtr = struct {
                    fn getTypedValuePtr(ptr: *anyopaque) anyerror!*anyopaque {
                        const self: *T = @ptrCast(@alignCast(ptr));

                        _ = try self.getValue();

                        if (self.value) |*val_ptr| {
                            return @ptrCast(val_ptr);
                        } else if (self.default_value) |*default_ptr| {
                            return @ptrCast(default_ptr);
                        } else {
                            return error.NoValueSet;
                        }
                    }
                }.getTypedValuePtr,
                .type_info = type_info,
            };
        };

        return Self{
            .ptr = option_ptr,
            .vtable = &Vtable.vtable,
        };
    }

    /// Get the description of the option
    pub fn getDescription(self: Self) []const u8 {
        return self.vtable.getDescription(self.ptr);
    }

    /// Get the default value as a string, returns null if no default is set
    pub fn getDefaultValueAsString(self: Self, allocator: std.mem.Allocator) !?[]u8 {
        return self.vtable.getDefaultValueAsString(self.ptr, allocator);
    }

    /// Get the value of the option as a string
    pub fn getValueAsString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.getValueAsString(self.ptr, allocator);
    }

    /// Set the value of the option from a string
    pub fn setValueFromString(self: Self, value: []const u8) !void {
        return self.vtable.setValueFromString(self.ptr, value);
    }

    /// Check if the option has a value set
    pub fn hasValue(self: Self) bool {
        return self.vtable.hasValue(self.ptr);
    }

    /// Get the long name of the option
    pub fn getName(self: Self) ?[]const u8 {
        return self.vtable.getName(self.ptr);
    }

    /// Get the short name of the option
    pub fn getShort(self: Self) ?u8 {
        return self.vtable.getShort(self.ptr);
    }

    /// Get the type information for type identification
    pub fn getTypeInfo(self: Self) TypeInfo {
        return self.vtable.type_info;
    }

    /// Get the type hash for type identification
    pub fn getTypeHash(self: Self) u64 {
        return self.vtable.type_info.hash;
    }

    /// Get the type name
    pub fn getTypeName(self: Self) []const u8 {
        return self.vtable.type_info.name;
    }

    /// Get the typed value of the option - caller must know the correct type
    /// The type must match exactly or TypeMismatch error will be returned
    pub fn getOptionValue(self: Self, comptime T: type) !T {
        // Verify the type matches
        const expected_hash = comptime std.hash_map.hashString(@typeName(T));
        if (self.vtable.type_info.hash != expected_hash) {
            return error.TypeMismatch;
        }

        // Get the typed value pointer and cast it back
        const value_ptr = try self.vtable.getTypedValuePtr(self.ptr);
        const typed_ptr: *T = @ptrCast(@alignCast(value_ptr));
        return typed_ptr.*;
    }

    /// Try to get the value as a specific type, returns null if type doesn't match
    pub fn tryGetValue(self: Self, comptime T: type) ?T {
        return self.getOptionValue(T) catch null;
    }

    /// Check if the option is of a specific type
    pub fn isType(self: Self, comptime T: type) bool {
        const expected_hash = comptime std.hash_map.hashString(@typeName(T));
        return self.vtable.type_info.hash == expected_hash;
    }
};
