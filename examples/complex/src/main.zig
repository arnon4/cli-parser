const std = @import("std");

const Argument = @import("parser").Argument;
const ActionContext = @import("parser").ActionContext;
const ActionFn = @import("parser").ActionFn;
const Command = @import("parser").Command;
const Flag = @import("parser").Flag;
const Option = @import("parser").Option;
const Parser = @import("parser").Parser;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create options
    var int_opt = try Option(i32).init("An integer option", allocator);
    defer int_opt.deinit();
    _ = int_opt.withName("int")
        .withShort('i')
        .withDefaultValue(42);

    const worker_struct = struct {
        name: []const u8,
        id: u32,
    };

    var worker_opt = try Option(worker_struct).init("Worker option", allocator);
    defer worker_opt.deinit();
    _ = worker_opt.withName("worker")
        .withShort('w');

    // Create arguments
    var str_arg = try Argument([]const u8).init("input", "A string argument", false, allocator);
    defer str_arg.deinit();

    // Create a struct argument for testing JSON parsing
    var struct_arg = try Argument(worker_struct).init("worker_arg", "A worker struct argument", true, allocator);
    _ = struct_arg.withArity(.{
        .min = 1,
        .max = 2,
    });
    defer struct_arg.deinit();

    // Create flags
    var flag = try Flag.init("Enable verbose output", false, allocator);
    _ = flag.withName("verbose").withShort('v');

    // Create action function
    const action: ActionFn = struct {
        fn call(context: ActionContext) !void {
            var buf: [512]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&buf);
            const out: *std.io.Writer = &writer.interface;
            try out.print("Sub command action called!\n", .{});

            // Get the global integer option
            const int_opt_value = context.getOption(i32, "int") catch unreachable; // Has default, so always present
            try out.print("Global integer option: {d}\n", .{int_opt_value});

            // Get the worker option (JSON struct)
            const worker_struct_value: ?worker_struct = context.getOption(worker_struct, "worker") catch null;
            if (worker_struct_value) |w| {
                try out.print("Worker from option: name={s}, id={d}\n", .{ w.name, w.id });
            } else {
                try out.print("No worker option provided.\n", .{});
            }

            // Get the string argument (by name)
            const input_value: ?[]const u8 = context.getArgument([]const u8, "input") catch null;
            if (input_value == null) {
                try out.print("No input argument provided.\n", .{});
            } else {
                try out.print("Input argument: {s}\n", .{input_value.?});
            }

            // Get the struct arguments (by name, JSON struct)
            var worker_args_buffer: [2]worker_struct = undefined; // Max arity is 2
            context.getArguments(worker_struct, "worker_arg", &worker_args_buffer) catch {
                std.debug.print("Error getting worker arguments\n", .{});
                std.process.exit(1);
            };

            if (worker_args_buffer.len == 0) {
                try out.print("No worker_arg arguments provided.\n", .{});
            } else {
                for (worker_args_buffer, 0..) |w, i| {
                    try out.print("Worker_arg[{d}]: name={s}, id={d}\n", .{ i, w.name, w.id });
                }
            }

            try out.print("Action completed successfully!\n", .{});
            try out.flush();
        }
    }.call;

    // Create command
    const cmd = try Command.init("demo", "A demo command", allocator);
    defer cmd.deinit();

    // Create subcommand
    const sub_cmd = try Command.init("sub", "A subcommand", allocator);
    defer sub_cmd.deinit();

    // Register options, arguments, flags, and action
    _ = sub_cmd.withOption(worker_struct, worker_opt)
        .withArgument([]const u8, str_arg)
        .withArgument(worker_struct, struct_arg)
        .withAction(action);

    _ = cmd.withOption(i32, int_opt)
        .withFlag(flag)
        .withSubcommand(sub_cmd); // Register the subcommand

    // Create parser
    var parser = Parser.init(cmd, allocator);
    defer parser.deinit();
    // Parse command line arguments and get both command and context
    const result = try parser.parse();

    try result.invoke();
}
