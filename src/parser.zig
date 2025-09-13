const std = @import("std");
const testing = @import("std").testing;
const ArgIterator = std.process.ArgIterator;
const option = @import("option.zig");
const flag = @import("flag.zig");
const argument = @import("argument.zig");
const command = @import("command.zig");
const action_context = @import("action_context.zig");
const ActionContext = action_context.ActionContext;
const ParsedValue = ActionContext.ParsedValue;
const Allocator = std.mem.Allocator;

const ParserConfig = struct {
    /// If false, treat the first positional argument as the end of options/flags
    allow_options_after_args: bool = true,
    /// If true, treat `--` as the end of options/flags
    double_hyphen_delimiter: bool = true,
    /// If true, ignore unknown options/flags instead of erroring
    allow_unknown_options: bool = false,
};

/// Parser for processing command-line arguments into command structures
pub fn Parser(comptime config: ParserConfig) type {
    return struct {
        const Self = @This();

        /// Result type for parse operations that include context
        pub const ParseResult = struct {
            command: *command.Command,
            context: *ActionContext,
            allocator: Allocator,

            /// Invoke the action associated with the parsed command
            pub fn invoke(self: *ParseResult) anyerror!void {
                return self.command.invoke(self.context);
            }
        };

        root_command: *command.Command,
        allocator: std.mem.Allocator,
        parse_result: ?*ParseResult,
        print_help: bool = false,
        has_errors: bool = false,

        /// Initialize the parser
        pub fn init(root_command: *command.Command, allocator: Allocator) Self {
            return Self{
                .root_command = root_command,
                .allocator = allocator,
                .parse_result = null,
            };
        }

        /// Deinitialize the parser and free resources
        pub fn deinit(self: *Self) void {
            if (self.parse_result) |result| {
                result.context.deinit(); // commands are managed by the user
                self.allocator.destroy(result);
            }
        }

        /// Parse command-line arguments and return both command and populated context
        pub fn parse(self: *Self) !*ParseResult {
            var args = try std.process.argsWithAllocator(self.allocator);
            _ = args.next(); // skip program name
            defer args.deinit();

            // Parse the arguments first
            self.parseArgs(&args);

            // Check if help should be printed first
            if (self.print_help) {
                const command_for_help = if (self.parse_result) |result| result.command else self.root_command;
                command_for_help.generateHelp(self.allocator) catch {
                    std.log.err("Failed to generate help message\n", .{});
                };
                std.process.exit(0);
            }

            // check if all required positional arguments are provided and meet arity requirements
            if (self.parse_result) |result| {
                for (result.command.arguments.items) |arg| {
                    const arg_name = arg.getName();
                    const arity = arg.getArity();
                    const maybe_value = result.context.arguments.get(arg_name);

                    var value_count: usize = 0;
                    if (maybe_value) |value| {
                        value_count = value.value.items.len;
                    }

                    if (value_count < arity.min) {
                        if (arg.isRequired()) {
                            std.log.err("Missing required positional argument: {s} (needs at least {d} value(s))\n", .{ arg_name, arity.min });
                        } else {
                            std.log.err("Argument {s} needs at least {d} value(s), got {d}\n", .{ arg_name, arity.min, value_count });
                        }
                        self.print_help = true;
                        self.has_errors = true;
                    }
                }
            }

            // Set default values for options that weren't provided
            self.setDefaultValues();

            // If there were parsing errors, print help and exit
            if (self.has_errors) {
                const command_for_help = if (self.parse_result) |result| result.command else self.root_command;
                command_for_help.generateHelp(self.allocator) catch {
                    std.log.err("Failed to generate help message\n", .{});
                };
                std.process.exit(1);
            }

            return self.parse_result.?;
        }

        fn parseArgs(self: *Self, args: *ArgIterator) void {
            var args_reached = false;
            self.parse_result = self.allocator.create(ParseResult) catch {
                self.has_errors = true;
                return;
            };

            self.parse_result.?.command = self.root_command;
            self.parse_result.?.context = ActionContext.init(self.allocator, null) catch {
                self.has_errors = true;
                return;
            };
            var positional_index: usize = 0;

            while (args.next()) |arg| {
                const arg_slice = arg[0..arg.len];

                // Process each argument
                if (std.mem.startsWith(u8, arg_slice, "-")) {
                    // Only break on options/flags if we've reached args and don't allow options after args
                    if (comptime config.allow_options_after_args == false) {
                        if (args_reached) {
                            // Treat as positional argument instead of option
                            self.parseCommandOrPositional(arg, &positional_index, &args_reached);
                            continue;
                        }
                    }
                    self.parseHyphenArg(arg_slice, @constCast(args), &args_reached, &positional_index);
                } else {
                    self.parseCommandOrPositional(arg, &positional_index, &args_reached);
                }
            }

            while (args.next()) |arg| {
                // if we reach here, all remaining args are positional
                self.setPositionalArgumentByIndex(arg, &positional_index);
            }
        }

        fn parseHyphenArg(self: *Self, arg: []const u8, args: *ArgIterator, args_reached: *bool, positional_index: *usize) void {
            if (comptime config.double_hyphen_delimiter) {
                if (std.mem.eql(u8, arg, "--")) {
                    args_reached.* = true;
                    return;
                }
            }

            if (std.mem.startsWith(u8, arg, "--") and arg.len > 2) {
                // Long option or flag
                self.parseLongOption(arg, args);
            } else if (!std.mem.startsWith(u8, arg, "--") and arg.len > 1) {
                // Short option(s) or flag(s)
                self.parseShortOptions(arg, args, positional_index, args_reached);
            } else {
                self.parseCommandOrPositional(arg, positional_index, args_reached);
            }
        }

        fn parseLongOption(self: *Self, arg: []const u8, args: *ArgIterator) void {
            var option_name: []const u8 = undefined;
            var option_value: ?[]const u8 = null;

            // Check for --option=value format
            if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                option_name = arg[2..eq_pos];
                option_value = arg[eq_pos + 1 ..];
            } else {
                option_name = arg[2..];
            }

            // Special case for --help
            if (std.mem.eql(u8, option_name, "help")) {
                self.print_help = true;
                return;
            }

            // First check if it's a flag
            for (self.parse_result.?.command.flags.items) |flag_item| {
                if (flag_item.name) |flag_name| {
                    if (std.mem.eql(u8, flag_name, option_name)) {
                        self.parse_result.?.context.setFlag(flag_name, true) catch {
                            self.has_errors = true;
                        };
                        // Check if this is the help flag
                        if (std.mem.eql(u8, flag_name, "help")) {
                            self.print_help = true;
                        }
                        return;
                    }
                }
            }

            // Then check if it's an option
            for (self.parse_result.?.command.options.items) |option_item| {
                if (option_item.getName()) |opt_name| {
                    if (std.mem.eql(u8, opt_name, option_name)) {
                        self.parseOptionValues(option_item, opt_name, option_value, args);
                        return;
                    }
                }
            }

            // Recursively check parent commands
            if (self.parse_result.?.command.parent) |parent_cmd| {
                const original_command = self.parse_result.?.command;
                self.parse_result.?.command = parent_cmd;
                self.parseLongOption(arg, args);
                self.parse_result.?.command = original_command;
                return;
            }

            if (comptime config.allow_unknown_options) {
                return; // silently ignore unknown options
            }
            std.log.err("Unknown option --{s}\n", .{option_name});
            self.has_errors = true;
            self.print_help = true;
        }

        fn parseShortOptions(self: *Self, arg: []const u8, args: *ArgIterator, positional_index: *usize, args_reached: *bool) void {
            var char_index: usize = 1; // Skip the '-'

            var option_name: []const u8 = undefined;
            var option_value: ?[]const u8 = null;

            // Check for -o=value format
            if (std.mem.indexOf(u8, arg, "=")) |eq_pos| {
                option_name = arg[1..eq_pos];
                option_value = arg[eq_pos + 1 ..];
                if (option_name.len == 0) {
                    std.log.err("Missing option name before '='\n", .{});
                    return;
                }
                _ = self.parseSinleShortOption(option_name[0], option_value.?);
                return;
            }

            // if length > 2, it must be multiple flags
            if (arg.len > 2) {
                while (char_index < arg.len) : (char_index += 1) {
                    const short_flag = arg[char_index];
                    _ = self.parseSingleShortFlag(short_flag);
                }
                return;
            }

            // if length == 2, it could be a single flag or a single option
            const short_char = arg[1];
            if (!self.parseSingleShortFlag(short_char)) {
                // Not a flag, try as an option
                option_value = args.next();
                if (comptime config.allow_options_after_args == false) {
                    if (!self.parseSinleShortOption(short_char, option_value)) {
                        // Treat as positional argument instead of option
                        self.parseCommandOrPositional(arg, positional_index, args_reached);
                        if (option_value) |val| {
                            self.setPositionalArgumentByIndex(val, positional_index);
                        }
                        return;
                    }
                }
            }
        }

        fn parseSingleShortFlag(self: *Self, short_char: u8) bool {
            for (self.parse_result.?.command.flags.items) |flag_item| {
                if (flag_item.short) |short| {
                    if (short == short_char) {
                        // Use flag name if available, otherwise use short character as string
                        if (flag_item.name) |flag_name| {
                            self.parse_result.?.context.setFlag(flag_name, true) catch {
                                self.has_errors = true;
                            };
                            // Check if this is the help flag
                            if (std.mem.eql(u8, flag_name, "help")) {
                                self.print_help = true;
                            }
                        } else {
                            // For flags without names, create a persistent single-character string
                            const short_str = self.allocator.dupe(u8, &[_]u8{short}) catch {
                                self.has_errors = true;
                                return true;
                            };
                            self.parse_result.?.context.setFlag(short_str, true) catch {
                                self.has_errors = true;
                            };
                        }
                        return true;
                    }
                }
            }

            // Recursively check parent commands
            if (self.parse_result.?.command.parent) |parent_cmd| {
                const original_command = self.parse_result.?.command;
                self.parse_result.?.command = parent_cmd;
                const found = self.parseSingleShortFlag(short_char);
                self.parse_result.?.command = original_command;
                return found;
            }

            return false;
        }

        fn parseOptionValues(self: *Self, option_item: anytype, opt_name: []const u8, initial_value: ?[]const u8, args: ?*ArgIterator) void {
            const arity = option_item.getArity();

            // Collect individual values (each owned slice) directly into an ArrayList.
            var list = std.ArrayList([]const u8).empty;
            var transferred = false;
            defer {
                if (!transferred) {
                    for (list.items) |v| self.allocator.free(v);
                    list.deinit(self.allocator);
                }
            }

            if (initial_value) |init_val| {
                const duped = self.allocator.dupe(u8, init_val) catch {
                    self.has_errors = true;
                    return;
                };
                list.append(self.allocator, duped) catch {
                    self.has_errors = true;
                    return;
                };
            }

            if (args) |arg_iter| {
                while (list.items.len < arity.max) {
                    const next_arg = arg_iter.next() orelse break;
                    if (std.mem.startsWith(u8, next_arg, "-")) {
                        break; // next option/flag begins
                    }
                    const duped = self.allocator.dupe(u8, next_arg) catch {
                        self.has_errors = true;
                        return;
                    };
                    list.append(self.allocator, duped) catch {
                        self.has_errors = true;
                        return;
                    };
                }
            }

            if (list.items.len < arity.min) {
                std.log.err("Option --{s} requires at least {d} value(s), got {d}\n", .{ opt_name, arity.min, list.items.len });
                self.has_errors = true;
                self.print_help = true;
                return;
            }
            if (list.items.len > arity.max) {
                std.log.err("Option --{s} accepts at most {d} value(s), got {d}\n", .{ opt_name, arity.max, list.items.len });
                self.has_errors = true;
                self.print_help = true;
                return;
            }
            if (list.items.len == 0 and arity.min == 0) return; // optional and not provided

            // Transfer ownership of the list (and its slices) into the context.
            self.parse_result.?.context.options.put(opt_name, ParsedValue{ .value = list }) catch {
                self.has_errors = true;
                return;
            };
            transferred = true;
        }

        fn parseSinleShortOption(self: *Self, short_char: u8, value: ?[]const u8) bool {
            for (self.parse_result.?.command.options.items) |option_item| {
                if (option_item.getShort()) |short| {
                    if (short == short_char) {
                        if (option_item.getName()) |opt_name| {
                            self.parseOptionValues(option_item, opt_name, value, null);
                            return true;
                        }
                    }
                }
            }

            // Recursively check parent commands
            if (self.parse_result.?.command.parent) |parent_cmd| {
                const original_command = self.parse_result.?.command;
                self.parse_result.?.command = parent_cmd;
                if (self.parseSinleShortOption(short_char, value)) {
                    self.parse_result.?.command = original_command;
                    return true;
                }
            }

            if (short_char == 'h') {
                self.print_help = true;
                return true;
            }

            if (comptime config.allow_unknown_options) {
                return false;
            }

            std.log.err("Unknown option -{c}\n", .{short_char});
            self.has_errors = true;
            self.print_help = true;
            return false;
        }

        fn parseCommandOrPositional(self: *Self, arg: []const u8, positional_index: *usize, args_reached: *bool) void {
            // Try to match subcommands
            for (self.parse_result.?.command.subcommands.items) |sub_cmd| {
                if (std.mem.eql(u8, sub_cmd.name, arg)) {
                    self.parse_result.?.command = sub_cmd;
                    const new_context = action_context.ActionContext.init(self.allocator, self.parse_result.?.context) catch {
                        self.has_errors = true;
                        return;
                    };
                    self.parse_result.?.context = new_context;
                    // Reset positional index for the new subcommand
                    positional_index.* = 0;
                    return;
                }
            }
            // If no subcommand matched, treat as positional argument
            if (comptime config.allow_options_after_args == false) {
                args_reached.* = true;
            }
            self.setPositionalArgumentByIndex(arg, positional_index);
        }

        fn setPositionalArgumentByIndex(self: *Self, arg: []const u8, positional_index: *usize) void {
            if (positional_index.* >= self.parse_result.?.command.arguments.items.len) {
                std.log.err("Unexpected positional argument: {s}\n", .{arg});
                self.print_help = true;
                self.has_errors = true;
                return;
            }

            const arg_item = self.parse_result.?.command.arguments.items[positional_index.*];
            const arg_name = arg_item.getName();

            // Check if this argument already has values
            const existing_values = self.parse_result.?.context.arguments.getPtr(arg_name);
            var current_count: usize = 0;

            if (existing_values) |existing| {
                current_count = existing.value.items.len;
            }

            const arity = arg_item.getArity();

            // Check if we can accept another value
            if (current_count >= arity.max) {
                std.log.err("Argument {s} accepts at most {d} value(s), but got more\n", .{ arg_name, arity.max });
                self.has_errors = true;
                self.print_help = true;
                return;
            }

            // Ensure we own the string by duplicating it
            const owned_value = self.parse_result.?.context.allocator.dupe(u8, arg) catch {
                self.has_errors = true;
                return;
            };

            if (existing_values) |existing| {
                existing.value.append(self.parse_result.?.context.allocator, owned_value) catch {
                    self.has_errors = true;
                    self.parse_result.?.context.allocator.free(owned_value);
                    return;
                };
            } else {
                var list = std.ArrayList([]const u8).empty;
                list.append(self.parse_result.?.context.allocator, owned_value) catch {
                    self.parse_result.?.context.allocator.free(owned_value);
                    self.has_errors = true;
                    return;
                };
                self.parse_result.?.context.arguments.put(arg_name, ParsedValue{ .value = list }) catch {
                    self.has_errors = true;
                    for (list.items) |v| self.parse_result.?.context.allocator.free(v);
                    list.deinit(self.parse_result.?.context.allocator);
                };
            }

            // Only advance positional index if this argument has reached its maximum arity
            if (current_count + 1 >= arity.max) {
                positional_index.* += 1;
            }
        }

        /// Set default values for options that weren't provided by the user
        fn setDefaultValues(self: *Self) void {
            if (self.parse_result == null) {
                return;
            }

            // Set defaults for current command and all parent commands
            var current_context = self.parse_result.?.context;
            var current_command = self.parse_result.?.command;

            while (true) {
                // Set defaults for current command's options
                for (current_command.options.items) |option_item| {
                    if (option_item.getName()) |opt_name| {
                        // Check if this option was already set
                        if (current_context.options.get(opt_name) == null) {
                            // Option wasn't set, check if it has a default value
                            const maybe_default = option_item.getDefaultValueAsString() catch null;
                            if (maybe_default) |defaults| {
                                var list = std.ArrayList([]const u8).empty;
                                const T = @TypeOf(defaults);
                                switch (@typeInfo(T)) {
                                    .pointer => |pinfo| if (pinfo.child == u8) {
                                        // Single string default; split on commas
                                        var it = std.mem.splitScalar(u8, defaults, ',');
                                        while (it.next()) |part| {
                                            const trimmed = std.mem.trim(u8, part, " \t");
                                            if (trimmed.len == 0) continue;
                                            const duped = self.allocator.dupe(u8, trimmed) catch {
                                                self.has_errors = true;
                                                break;
                                            };
                                            list.append(self.allocator, duped) catch {
                                                self.has_errors = true;
                                                break;
                                            };
                                        }
                                        self.allocator.free(defaults); // free original combined string
                                    } else {
                                        // Treat as array-of-slices pointer
                                        for (defaults) |d| {
                                            const duped = self.allocator.dupe(u8, d) catch {
                                                self.has_errors = true;
                                                break;
                                            };
                                            list.append(self.allocator, duped) catch {
                                                self.has_errors = true;
                                                break;
                                            };
                                        }
                                        // free container
                                        self.allocator.free(defaults);
                                    },
                                    else => {},
                                }
                                if (list.items.len > 0) {
                                    current_context.options.put(opt_name, ParsedValue{ .value = list }) catch {
                                        self.has_errors = true;
                                        for (list.items) |s| self.allocator.free(s);
                                        list.deinit(self.allocator);
                                    };
                                } else {
                                    for (list.items) |s| self.allocator.free(s);
                                    list.deinit(self.allocator);
                                }
                            }
                        }
                    }
                }

                // Move to parent command and context
                if (current_command.parent) |parent_cmd| {
                    current_command = parent_cmd;
                    if (current_context.parent) |parent_ctx| {
                        current_context = parent_ctx;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
        }
    };
}
