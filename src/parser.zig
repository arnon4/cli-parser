const std = @import("std");
const testing = @import("std").testing;
const option = @import("option.zig");
const flag = @import("flag.zig");
const argument = @import("argument.zig");
const command = @import("command.zig");
const action_context = @import("action_context.zig");

/// Parser for processing command-line arguments into command structures
pub const Parser = struct {
    const Self = @This();

    /// Result type for parse operations that include context
    pub const ParseResult = struct {
        command: *command.Command,
        context: *action_context.ActionContext,
    };

    root_command: *command.Command,
    allocator: std.mem.Allocator,

    /// Initialize the parser
    pub fn init(root_command: *command.Command, allocator: std.mem.Allocator) Self {
        return Self{
            .root_command = root_command,
            .allocator = allocator,
        };
    }

    /// Parse command-line arguments and return the command to invoke
    pub fn parse(self: *Self) !*command.Command {
        const args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        return try self.parseArgs(args);
    }

    /// Parse command-line arguments and return both command and populated context
    pub fn parseWithContext(self: *Self) !ParseResult {
        // Get arguments using argsAlloc
        const args = try std.process.argsAlloc(self.allocator);
        defer std.process.argsFree(self.allocator, args);

        return try self.parseArgsWithContext(args);
    }

    /// Parse provided arguments and return both command and context
    pub fn parseArgsWithContext(self: *Self, args: [][:0]u8) !ParseResult {
        var args_slice = try self.allocator.alloc([]const u8, args.len);
        defer self.allocator.free(args_slice);

        for (args, 0..) |arg, i| {
            args_slice[i] = arg;
        }

        const result_command = try self.parseArgs(args_slice);
        var context = try action_context.ActionContext.init(self.allocator, null);

        for (result_command.options.items) |opt| {
            if (opt.vtable.getName(opt.ptr)) |opt_name| {
                if (opt.vtable.hasValue(opt.ptr)) {
                    const type_info = opt.vtable.type_info;

                    if (std.mem.indexOf(u8, type_info.name, "struct") != null) {
                        const value_str = try opt.vtable.getValueAsString(opt.ptr, self.allocator);
                        defer self.allocator.free(value_str);
                        const owned_value = try self.allocator.dupe(u8, value_str);
                        try context.setOption(opt_name, action_context.ActionContext.ParsedValue{ .string = owned_value });
                    } else {
                        const value_str = try opt.vtable.getValueAsString(opt.ptr, self.allocator);
                        defer self.allocator.free(value_str);
                        const owned_value = try self.allocator.dupe(u8, value_str);
                        try context.setOption(opt_name, action_context.ActionContext.ParsedValue{ .string = owned_value });
                    }
                }
            }
        }

        for (result_command.flags.items) |fl| {
            if (fl.name) |flag_name| {
                try context.setFlag(flag_name, fl.getValue());
            }
        }

        if (result_command.arguments.items.len > 0) {
            for (result_command.arguments.items) |arg| {
                if (arg.vtable.hasValue(arg.ptr)) {
                    const value = try arg.vtable.getValue(arg.ptr);
                    defer self.allocator.free(value); // Free the original allocated string
                    const owned_value = try self.allocator.dupe(u8, value);
                    const arg_name = arg.vtable.getName(arg.ptr);
                    try context.setArgument(arg_name, action_context.ActionContext.ParsedValue{ .string = owned_value });
                }
            }
        }

        // Check if help flag was set
        for (result_command.flags.items) |fl| {
            if (fl.name) |name| {
                if (std.mem.eql(u8, name, "help") and fl.getValue()) {
                    const help_text = try result_command.generateHelp(self.allocator);
                    defer self.allocator.free(help_text);
                    std.debug.print("{s}", .{help_text});
                    context.deinit();
                    std.process.exit(0);
                }
            }
        }

        return ParseResult{
            .command = result_command,
            .context = context,
        };
    }

    /// Parse provided arguments array and return the command to invoke
    pub fn parseArgs(self: *Self, args: [][]const u8) !*command.Command {
        if (args.len == 0) {
            return self.root_command;
        }

        var current_command = self.root_command;
        var arg_index: usize = 1; // Skip program name

        var positional_index: usize = 0;

        outer: while (arg_index < args.len) {
            const arg = args[arg_index];
            arg_index += 1;

            // Check for double dash delimiter
            if (std.mem.eql(u8, arg, "--")) {
                // Everything after -- is positional arguments
                while (arg_index < args.len) {
                    try self.setPositionalArgument(current_command, args[arg_index], &positional_index);
                    arg_index += 1;
                }
                break;
            }

            for (current_command.subcommands.items) |sub_cmd| {
                if (std.mem.eql(u8, sub_cmd.name, arg)) {
                    current_command = sub_cmd;
                    continue :outer;
                }
            }

            // Handle options and flags
            if (arg.len > 1 and arg[0] == '-') {
                if (arg[1] == '-') {
                    // Long option
                    arg_index = try self.parseLongOption(current_command, args, arg_index - 1);
                } else {
                    // Short option(s)
                    arg_index = try self.parseShortOptions(current_command, args, arg_index - 1);
                }
                continue;
            }

            self.setPositionalArgument(current_command, arg, &positional_index) catch |err| {
                if (current_command.action == null) {
                    // Only print help -- no need to show error text
                    const help_text = current_command.generateHelp(self.allocator) catch |help_err| {
                        std.debug.print("Failed to generate help: {}\n", .{help_err});
                        std.process.exit(1);
                    };
                    defer self.allocator.free(help_text);
                    std.debug.print("{s}\n", .{help_text});
                    std.process.exit(1);
                }
                self.handleArgumentParseError(current_command, positional_index, arg, err);
            };
        }

        return current_command;
    }

    /// Parse a long option (--option)
    fn parseLongOption(self: *Self, cmd: *command.Command, args: [][]const u8, start_index: usize) !usize {
        const arg = args[start_index];
        var option_name: []const u8 = undefined;
        var option_value: ?[]const u8 = null;

        // Check for --option=value format
        if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
            option_name = arg[2..eq_pos];
            option_value = arg[eq_pos + 1 ..];
        } else {
            option_name = arg[2..];
        }

        // First check if it's a flag
        for (cmd.flags.items) |flag_item| {
            if (flag_item.name) |flag_name| {
                if (std.mem.eql(u8, flag_name, option_name)) {
                    flag_item.setFlag();
                    return start_index + 1;
                }
            }
        }

        for (cmd.options.items) |option_item| {
            if (option_item.vtable.getName(option_item.ptr)) |opt_name| {
                if (std.mem.eql(u8, opt_name, option_name)) {
                    if (option_value) |value| {
                        option_item.vtable.setValueFromString(option_item.ptr, value) catch |err| {
                            return self.handleOptionParseError(cmd, opt_name, value, err);
                        };
                    } else {
                        // Value should be next argument
                        if (start_index + 1 >= args.len) {
                            return error.MissingOptionValue;
                        }
                        option_item.vtable.setValueFromString(option_item.ptr, args[start_index + 1]) catch |err| {
                            return self.handleOptionParseError(cmd, opt_name, args[start_index + 1], err);
                        };
                        return start_index + 2;
                    }
                    return start_index + 1;
                }
            }
        }

        return error.UnknownOption;
    }

    /// Parse short option(s) (-o or -abc)
    fn parseShortOptions(self: *Self, cmd: *command.Command, args: [][]const u8, start_index: usize) !usize {
        const arg = args[start_index];
        var char_index: usize = 1; // Skip the '-'

        while (char_index < arg.len) {
            const short_char = arg[char_index];

            // First check if it's a flag
            var found = false;
            for (cmd.flags.items) |flag_item| {
                if (flag_item.short) |short| {
                    if (short == short_char) {
                        flag_item.setFlag();
                        found = true;
                        break;
                    }
                }
            }

            if (found) {
                char_index += 1;
                continue;
            }

            // Check parent command flags
            if (cmd.parent) |parent_cmd| {
                for (parent_cmd.flags.items) |flag_item| {
                    if (flag_item.short) |short| {
                        if (short == short_char) {
                            flag_item.setFlag();
                            found = true;
                            break;
                        }
                    }
                }
            }

            // Then check if it's an option
            for (cmd.options.items) |option_item| {
                if (option_item.vtable.getShort(option_item.ptr)) |short| {
                    if (short == short_char) {
                        if (char_index + 1 < arg.len) {
                            option_item.vtable.setValueFromString(option_item.ptr, arg[char_index + 1 ..]) catch |err| {
                                const short_str = [_]u8{short_char};
                                return self.handleOptionParseError(cmd, &short_str, arg[char_index + 1 ..], err);
                            };
                            return start_index + 1;
                        } else {
                            // Value should be next argument
                            if (start_index + 1 >= args.len) {
                                return error.MissingOptionValue;
                            }
                            option_item.vtable.setValueFromString(option_item.ptr, args[start_index + 1]) catch |err| {
                                const short_str = [_]u8{short_char};
                                return self.handleOptionParseError(cmd, &short_str, args[start_index + 1], err);
                            };
                            return start_index + 2;
                        }
                    }
                }
            }

            // Check parent command options
            if (cmd.parent) |parent_cmd| {
                for (parent_cmd.options.items) |option_item| {
                    if (option_item.vtable.getShort(option_item.ptr)) |short| {
                        if (short == short_char) {
                            if (char_index + 1 < arg.len) {
                                option_item.vtable.setValueFromString(option_item.ptr, arg[char_index + 1 ..]) catch |err| {
                                    const short_str = [_]u8{short_char};
                                    return self.handleOptionParseError(parent_cmd, &short_str, arg[char_index + 1 ..], err);
                                };
                                return start_index + 1;
                            } else {
                                // Value should be next argument
                                if (start_index + 1 >= args.len) {
                                    return error.MissingOptionValue;
                                }
                                option_item.vtable.setValueFromString(option_item.ptr, args[start_index + 1]) catch |err| {
                                    const short_str = [_]u8{short_char};
                                    return self.handleOptionParseError(parent_cmd, &short_str, args[start_index + 1], err);
                                };
                                return start_index + 2;
                            }
                        }
                    }
                }
            }

            // If we reach here, the short option was not found
            return error.UnknownOption;
        }

        return start_index + 1;
    }

    /// Set a positional argument value
    fn setPositionalArgument(self: *Self, cmd: *command.Command, value: []const u8, positional_index: *usize) !void {
        _ = self;

        if (positional_index.* >= cmd.arguments.items.len) {
            return error.TooManyArguments;
        }

        const arg_item = cmd.arguments.items[positional_index.*];
        try arg_item.vtable.setValue(arg_item.ptr, value);
        positional_index.* += 1;
    }

    /// Handle argument parse errors with helpful messages and help display
    fn handleArgumentParseError(self: *Self, cmd: *const command.Command, arg_index: usize, input_value: []const u8, err: anyerror) noreturn {
        std.debug.print("Error: Failed to parse argument at position {d}\n", .{arg_index + 1});
        std.debug.print("Input value: {s}\n", .{input_value});
        std.debug.print("Parse error: {}\n\n", .{err});

        const help_text = cmd.generateHelp(self.allocator) catch |help_err| {
            std.debug.print("Failed to generate help: {}\n", .{help_err});
            std.process.exit(1);
        };
        defer self.allocator.free(help_text);

        std.debug.print("{s}\n", .{help_text});
        std.process.exit(1);
    }

    /// Handle option parse errors with helpful messages and help display
    fn handleOptionParseError(self: *Self, cmd: *const command.Command, option_name: []const u8, input_value: []const u8, err: anyerror) noreturn {
        std.debug.print("Error: Failed to parse option '--{s}'\n", .{option_name});
        std.debug.print("Input value: {s}\n", .{input_value});
        std.debug.print("Parse error: {}\n\n", .{err});

        const help_text = cmd.generateHelp(self.allocator) catch |help_err| {
            std.debug.print("Failed to generate help: {}\n", .{help_err});
            std.process.exit(1);
        };
        defer self.allocator.free(help_text);

        std.debug.print("{s}", .{help_text});
        std.process.exit(1);
    }
};
