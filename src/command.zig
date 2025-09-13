const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const log = std.log;

const Option = @import("option.zig").Option;
const OptionInterface = @import("option.zig").OptionInterface;
const OptConfig = @import("opt_config.zig");
const Flag = @import("flag.zig").Flag;
const Argument = @import("argument.zig").Argument;
const ArgumentInterface = @import("argument.zig").ArgumentInterface;
const ArgConfig = @import("arg_config.zig");
const ActionContext = @import("action_context.zig").ActionContext;
const ExitCode = @import("exit_code.zig").ExitCode;
const exit = @import("exit_code.zig").exit;

const ArrayList = std.ArrayList;
/// Function pointer type for command actions
pub const ActionFn = *const fn (context: ActionContext) anyerror!void;

const HELP_PADDING: usize = 30;

/// Command struct
pub const Command = struct {
    const Self = @This();

    name: []const u8,
    description: []const u8,
    parent: ?*Self = null,
    action: ?ActionFn = null,
    allocator: Allocator,

    options: ArrayList(OptionInterface) = .empty,
    flags: ArrayList(*Flag) = .empty,
    arguments: ArrayList(ArgumentInterface) = .empty,
    subcommands: ArrayList(*Self) = .empty,

    /// Initialize a command
    pub fn init(name: []const u8, description: []const u8, allocator: Allocator) !*Self {
        const command = try allocator.create(Self);
        command.* = Self{
            .name = name,
            .description = description,
            .allocator = allocator,
            .options = ArrayList(OptionInterface).empty,
            .flags = ArrayList(*Flag).empty,
            .arguments = ArrayList(ArgumentInterface).empty,
            .subcommands = ArrayList(*Self).empty,
        };

        return command;
    }

    /// Deinitialize the command
    pub fn deinit(self: *Self) void {
        for (self.flags.items) |fl| {
            fl.deinit();
        }
        self.options.deinit(self.allocator);
        self.flags.deinit(self.allocator);
        self.arguments.deinit(self.allocator);
        self.subcommands.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Set the parent command (for subcommands)
    pub fn withParent(self: *Self, parent: *Self) *Self {
        self.parent = parent;
        return self;
    }

    /// Add an option to the command
    pub fn withOption(self: *Self, comptime config: OptConfig, concrete_option: *Option(config)) *Self {
        const option_interface = OptionInterface.init(config, concrete_option);
        self.options.append(self.allocator, option_interface) catch {
            log.err("Failed to add option: {s}", .{concrete_option.getName().?});
            exit(ExitCode.OutOfMemory);
        };

        return self;
    }

    /// Add a flag to the command
    pub fn withFlag(self: *Self, command_flag: *Flag) *Self {
        self.flags.append(self.allocator, command_flag) catch {
            log.err("Failed to add flag: {s}", .{command_flag.name.?});
            exit(ExitCode.OutOfMemory);
        };

        return self;
    }

    /// Add an argument to the command
    pub fn withArgument(self: *Self, comptime config: ArgConfig, concrete_argument: *Argument(config)) *Self {
        const argument_interface = ArgumentInterface.init(config, concrete_argument);
        // ensure optional arguments come after required ones
        if (concrete_argument.isRequired()) {
            for (self.arguments.items) |arg| {
                if (!arg.vtable.isRequired(arg.ptr)) {
                    log.err("Cannot add required argument '{s}' after optional arguments", .{concrete_argument.getName()});
                    exit(ExitCode.InvalidConfiguration);
                }
            }
        }

        self.arguments.append(self.allocator, argument_interface) catch {
            log.err("Failed to add argument: {s}", .{concrete_argument.getName()});
            exit(ExitCode.OutOfMemory);
        };

        return self;
    }

    /// Add a subcommand
    pub fn withSubcommand(self: *Self, subcommand: *Self) *Self {
        subcommand.parent = self;
        self.subcommands.append(self.allocator, subcommand) catch {
            log.err("Failed to add subcommand: {s}", .{subcommand.name});
            exit(ExitCode.OutOfMemory);
        };

        return self;
    }

    /// Set the action for leaf commands
    pub fn withAction(self: *Self, action: ActionFn) *Self {
        self.action = action;

        return self;
    }

    /// Check if this is a leaf command (has an action)
    pub fn isLeaf(self: *const Self) bool {
        return self.action != null;
    }

    /// Check if this is the root command (has no parent)
    pub fn isRoot(self: *const Self) bool {
        return self.parent == null;
    }

    /// Get the parent command
    pub fn getParent(self: *const Self) ?*Self {
        return self.parent;
    }

    /// Execute the command's action with a pre-populated context
    pub fn invoke(self: *const Self, context: *ActionContext) !void {
        if (self.action) |action| {
            try action(context.*);
        } else {
            // No action defined, print help
            try self.generateHelp(context.allocator);
        }
    }

    /// Generate help text for this command
    pub fn generateHelp(self: *const Self, allocator: Allocator) !void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        var writer = std.fs.File.stdout().writer(buf.items);
        const out: *std.io.Writer = &writer.interface;

        try out.print("{s} - {s}\n\n", .{ self.name, self.description });
        try out.print("USAGE:\n    {s}", .{self.name});

        if (self.options.items.len > 0 or self.flags.items.len > 0) {
            try out.print(" [OPTIONS]", .{});
        }

        if (self.subcommands.items.len > 0) {
            try out.print(" <COMMAND>", .{});
        }

        for (self.arguments.items) |arg| {
            if (arg.vtable.isRequired(arg.ptr)) {
                try out.print(" <{s}>", .{arg.vtable.getName(arg.ptr)});
            } else {
                try out.print(" [{s}]", .{arg.vtable.getName(arg.ptr)});
            }
        }
        try out.print("\n\n", .{});

        if (self.arguments.items.len > 0) {
            try out.print("ARGUMENTS:\n", .{});
            for (self.arguments.items) |arg| {
                const required_str = if (arg.vtable.isRequired(arg.ptr)) "required" else "optional";
                const arg_name = arg.vtable.getName(arg.ptr);
                const description = arg.vtable.getDescription(arg.ptr);

                var arg_line = ArrayList(u8).empty;
                defer arg_line.deinit(allocator);

                try arg_line.writer(allocator).print("  {s}", .{arg_name});

                const arg_str = arg_line.items;

                if (arg_str.len <= HELP_PADDING) {
                    try out.print("{s}", .{arg_str});
                    const padding = HELP_PADDING - arg_str.len;
                    var i: usize = 0;
                    while (i < padding) : (i += 1) {
                        try out.print(" ", .{});
                    }
                    try out.print("{s} ({s})\n", .{ description, required_str });
                } else {
                    try out.print("{s}\n", .{arg_str});
                    try out.print("                              {s} ({s})\n", .{ description, required_str });
                }
            }
            try out.print("\n", .{});
        }

        // Options section
        if (self.options.items.len > 0) {
            try out.print("OPTIONS:\n", .{});
            for (self.options.items) |opt| {
                if (opt.vtable.getName(opt.ptr)) |name| {
                    // Build the option flag line
                    var flag_line = ArrayList(u8).empty;
                    defer flag_line.deinit(allocator);

                    try flag_line.appendSlice(allocator, "  ");
                    if (opt.vtable.getShort(opt.ptr)) |short| {
                        try flag_line.writer(allocator).print("-{c}, --{s}[=VALUE]", .{ short, name });
                    } else {
                        try flag_line.writer(allocator).print("    --{s}[=VALUE]", .{name});
                    }

                    const flag_str = flag_line.items;
                    const description = opt.vtable.getDescription(opt.ptr);

                    // Get default value if it exists
                    var full_description = ArrayList(u8).empty;
                    defer full_description.deinit(allocator);

                    try full_description.appendSlice(allocator, description);

                    if (try opt.vtable.getDefaultValueAsString(opt.ptr)) |default_str| {
                        defer allocator.free(default_str);
                        try full_description.writer(allocator).print(" (default: {s})", .{default_str});
                    }

                    if (flag_str.len <= HELP_PADDING) {
                        try out.print("{s}", .{flag_str});
                        const padding = HELP_PADDING - flag_str.len;
                        var i: usize = 0;
                        while (i < padding) : (i += 1) {
                            try out.print(" ", .{});
                        }
                        try out.print("{s}\n", .{full_description.items});
                    } else {
                        try out.print("{s}\n", .{flag_str});
                        try out.print("                              {s}\n", .{full_description.items});
                    }
                }
            }
            try out.print("\n", .{});
        }

        var has_flags = false;

        for (self.flags.items) |fl| {
            if (fl.name) |name| {
                if (!std.mem.eql(u8, name, "help")) {
                    if (!has_flags) {
                        try out.print("FLAGS:\n", .{});
                        has_flags = true;
                    }

                    var flag_line = ArrayList(u8).empty;
                    defer flag_line.deinit(allocator);

                    try flag_line.appendSlice(allocator, "  ");
                    if (fl.short) |short| {
                        try flag_line.writer(allocator).print("-{c}, --{s}", .{ short, name });
                    } else {
                        try flag_line.writer(allocator).print("    --{s}", .{name});
                    }

                    const flag_str = flag_line.items;
                    const description = fl.getDescription();

                    if (flag_str.len <= HELP_PADDING) {
                        try out.print("{s}", .{flag_str});
                        const padding = HELP_PADDING - flag_str.len;
                        var i: usize = 0;
                        while (i < padding) : (i += 1) {
                            out.print(" ", .{}) catch {
                                std.debug.print("Fatal error occurred", .{});
                                std.process.exit(1);
                            };
                        }
                        try out.print("{s}\n", .{description});
                    } else {
                        try out.print("{s}\n", .{flag_str});
                        try out.print("                              {s}\n", .{description});
                    }
                }
            }
        }

        if (!has_flags) {
            try out.print("FLAGS:\n", .{});
        }

        const help_flag_str = "  -h, --help";
        try out.print("{s}", .{help_flag_str});
        const padding = HELP_PADDING - help_flag_str.len;
        const padding_str = " " ** padding;
        try out.print("{s}", .{padding_str});
        try out.print("Print this message and exit\n", .{});

        if (self.subcommands.items.len > 0) {
            try out.print("\nCOMMANDS:\n", .{});
            for (self.subcommands.items) |sub| {
                try out.print("  {s}\n", .{sub.name});
                try out.print("          {s}\n", .{sub.description});
            }
        }
    }

    /// Find an option by name
    pub fn findOption(self: *const Self, name: []const u8) ?OptionInterface {
        for (self.options.items) |opt| {
            if (opt.getName()) |opt_name| {
                if (std.mem.eql(u8, opt_name, name)) {
                    return opt;
                }
            }
        }

        // Check parent options if not found
        if (self.parent) |parent| {
            return parent.findOption(name);
        }

        return null;
    }

    /// Find an option by short flag
    pub fn findOptionByShort(self: *const Self, short: u8) ?OptionInterface {
        for (self.options.items) |opt| {
            if (opt.getShort()) |opt_short| {
                if (opt_short == short) {
                    return opt;
                }
            }
        }

        // Check parent options if not found
        if (self.parent) |parent| {
            return parent.findOptionByShort(short);
        }

        return null;
    }

    /// Find a flag by name
    pub fn findFlag(self: *const Self, name: []const u8) ?*Flag {
        for (self.flags.items) |command_flag| {
            if (command_flag.getName()) |flag_name| {
                if (std.mem.eql(u8, flag_name, name)) {
                    return command_flag;
                }
            }
        }

        // Check parent flags if not found
        if (self.parent) |parent| {
            return parent.findFlag(name);
        }

        return null;
    }

    /// Find a flag by short character
    pub fn findFlagByShort(self: *const Self, short: u8) ?*Flag {
        for (self.flags.items) |command_flag| {
            if (command_flag.getShort()) |flag_short| {
                if (flag_short == short) {
                    return command_flag;
                }
            }
        }

        // Check parent flags if not found
        if (self.parent) |parent| {
            return parent.findFlagByShort(short);
        }

        return null;
    }

    /// Get the command name
    pub fn getName(self: *const Self) []const u8 {
        return self.name;
    }

    /// Get the command description
    pub fn getDescription(self: *const Self) []const u8 {
        return self.description;
    }
};
