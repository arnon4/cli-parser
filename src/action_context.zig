const std = @import("std");

/// Context containing parsed CLI values
pub const ActionContext = struct {
    const Self = @This();

    options: std.StringHashMap(ParsedValue),
    flags: std.StringHashMap(bool),
    arguments: std.StringHashMap(ParsedValue),
    allocator: std.mem.Allocator,

    pub const ParsedValue = union(enum) {
        string: []const u8,
        int: i64,
        float: f64,
        bool: bool,
        struct_data: StructData,

        pub const StructData = struct {
            ptr: *anyopaque,
            type_info: TypeInfo,
            deinit_fn: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        };

        pub const TypeInfo = struct {
            name: []const u8,
            size: usize,
            alignment: u29,
        };

        pub fn asString(self: ParsedValue) []const u8 {
            return switch (self) {
                .string => |s| s,
                else => "",
            };
        }

        pub fn asInt(self: ParsedValue, comptime T: type) T {
            return switch (self) {
                .int => |i| @intCast(i),
                else => 0,
            };
        }

        pub fn asFloat(self: ParsedValue, comptime T: type) T {
            return switch (self) {
                .float => |f| @floatCast(f),
                else => 0.0,
            };
        }

        pub fn asBool(self: ParsedValue) bool {
            return switch (self) {
                .bool => |b| b,
                else => false,
            };
        }

        pub fn asStruct(self: ParsedValue, comptime T: type) ?T {
            return switch (self) {
                .struct_data => |data| {
                    const expected_name = @typeName(T);
                    if (!std.mem.eql(u8, data.type_info.name, expected_name)) {
                        return null;
                    }

                    const typed_ptr: *T = @ptrCast(@alignCast(data.ptr));
                    return typed_ptr.*;
                },
                else => null,
            };
        }

        /// Create a ParsedValue from a struct
        pub fn fromStruct(comptime T: type, value: T, allocator: std.mem.Allocator) !ParsedValue {
            const ptr = try allocator.create(T);
            ptr.* = value;

            return ParsedValue{
                .struct_data = StructData{
                    .ptr = ptr,
                    .type_info = TypeInfo{
                        .name = @typeName(T),
                        .size = @sizeOf(T),
                        .alignment = @alignOf(T),
                    },
                    .deinit_fn = struct {
                        fn deinit(ptr_opaque: *anyopaque, alloc: std.mem.Allocator) void {
                            const typed_ptr: *T = @ptrCast(@alignCast(ptr_opaque));
                            alloc.destroy(typed_ptr);
                        }
                    }.deinit,
                },
            };
        }
    };

    /// Initialize the action context
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .options = std.StringHashMap(ParsedValue).init(allocator),
            .flags = std.StringHashMap(bool).init(allocator),
            .arguments = std.StringHashMap(ParsedValue).init(allocator),
            .allocator = allocator,
        };
    }

    /// Deinitialize the context
    pub fn deinit(self: *Self) void {
        var options_iter = self.options.iterator();
        while (options_iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .struct_data => |data| {
                    if (data.deinit_fn) |deinit_fn| {
                        deinit_fn(data.ptr, self.allocator);
                    }
                },
                else => {},
            }
        }

        self.options.deinit();
        self.flags.deinit();

        var arguments_iter = self.arguments.iterator();
        while (arguments_iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .struct_data => |data| {
                    if (data.deinit_fn) |deinit_fn| {
                        deinit_fn(data.ptr, self.allocator);
                    }
                },
                else => {},
            }
        }

        self.arguments.deinit();
    }

    /// Set an option value
    pub fn setOption(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.options.put(name, value);
    }

    /// Set a flag value
    pub fn setFlag(self: *Self, name: []const u8, value: bool) !void {
        try self.flags.put(name, value);
    }

    /// Set an argument value
    pub fn setArgument(self: *Self, name: []const u8, value: ParsedValue) !void {
        try self.arguments.put(name, value);
    }

    /// Get an option value by name and type
    pub fn getOption(self: *const Self, comptime T: type, name: []const u8) ?T {
        if (self.options.get(name)) |value| {
            return switch (T) {
                []const u8 => value.asString(),
                i32, i64 => value.asInt(T),
                f32, f64 => value.asFloat(T),
                bool => value.asBool(),
                else => blk: {
                    const type_info = @typeInfo(T);
                    if (type_info == .@"struct") {
                        if (value.asStruct(T)) |struct_val| {
                            break :blk struct_val;
                        }

                        const json_str = value.asString();
                        if (json_str.len > 0) {
                            const parsed = std.json.parseFromSlice(T, self.allocator, json_str, .{
                                .ignore_unknown_fields = true,
                            }) catch {
                                break :blk null;
                            };
                            defer parsed.deinit();
                            break :blk parsed.value;
                        }
                    }
                    break :blk null;
                },
            };
        }
        return null;
    }

    /// Get a flag value by name
    pub fn getFlag(self: *const Self, name: []const u8) bool {
        return self.flags.get(name) orelse false;
    }

    /// Get an argument value by name and type
    pub fn getArgument(self: *const Self, comptime T: type, name: []const u8) ?T {
        if (self.arguments.get(name)) |value| {
            return switch (T) {
                []const u8 => value.asString(),
                i32, i64 => value.asInt(T),
                f32, f64 => value.asFloat(T),
                bool => value.asBool(),
                else => {
                    if (@typeInfo(T) == .@"struct") {
                        const json_str = value.asString();
                        const parsed = std.json.parseFromSlice(
                            T,
                            self.allocator,
                            json_str,
                            .{ .ignore_unknown_fields = true },
                        ) catch return null;
                        defer parsed.deinit();
                        return parsed.value;
                    }
                    return null;
                },
            };
        }
        return null;
    }
};
