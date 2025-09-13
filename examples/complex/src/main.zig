const std = @import("std");

const Argument = @import("parser").Argument;
const ArgConfig = @import("parser").ArgConfig;
const ActionContext = @import("parser").ActionContext;
const ActionFn = @import("parser").ActionFn;
const Command = @import("parser").Command;
const Flag = @import("parser").Flag;
const Option = @import("parser").Option;
const OptConfig = @import("parser").OptConfig;
const Parser = @import("parser").Parser;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create options
    const int_opt_config = OptConfig{
        .type = i32,
        .long_name = "int",
        .short_name = 'i',
        .description = "An integer option",
    };
    const int_opt = try Option(int_opt_config).init(allocator);

    const worker_struct = struct {
        name: []const u8,
        id: u32,
    };

    const worker_opt_config = OptConfig{
        .type = worker_struct,
        .long_name = "worker",
        .short_name = 'w',
        .description = "A worker struct option (JSON)",
    };
    const worker_opt = try Option(worker_opt_config).init(allocator);

    // Create arguments
    const str_arg_config = ArgConfig{
        .type = []const u8,
        .name = "input",
        .description = "A string argument",
        .required = true,
    };
    const str_arg = try Argument(str_arg_config).init(allocator); // required arguments may only have arity of 1

    // Create a struct argument for testing JSON parsing
    const struct_arg_config = ArgConfig{
        .type = worker_struct,
        .name = "worker_arg",
        .description = "A worker struct argument",
        .required = false,
    };
    var struct_arg = try Argument(struct_arg_config).init(allocator);

    _ = struct_arg.withArity(.{
        .min = 1,
        .max = 2,
    });

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
            const worker_count = context.getArguments(worker_struct, "worker_arg", &worker_args_buffer) catch {
                std.debug.print("Error getting worker arguments\n", .{});
                std.process.exit(1);
            };

            if (worker_count == 0) {
                try out.print("No worker_arg arguments provided.\n", .{});
            } else {
                for (0..worker_count) |i| {
                    try out.print("Worker_arg[{d}]: name={s}, id={d}\n", .{ i, worker_args_buffer[i].name, worker_args_buffer[i].id });
                }
            }

            try out.print("Action completed successfully!\n", .{});
            try out.flush();
        }
    }.call;

    // Create command
    const cmd = try Command.init("demo", "A demo command", allocator);

    // Create subcommand
    const sub_cmd = try Command.init("sub", "A subcommand", allocator);

    // Register options, arguments, flags, and action
    _ = sub_cmd.withOption(worker_opt_config, worker_opt)
        .withArgument(str_arg_config, str_arg)
        .withArgument(struct_arg_config, struct_arg) // Required arguments must be added before optional arguments
        .withAction(action);

    _ = cmd.withOption(int_opt_config, int_opt)
        .withFlag(flag)
        .withSubcommand(sub_cmd); // Register the subcommand

    // Create parser
    var parser = Parser(.{
        // default configuration
        .allow_unknown_options = false,
        .double_hyphen_delimiter = true,
        .allow_options_after_args = true,
    }).init(cmd, allocator);
    // Parse command line arguments and get both command and context
    const result = try parser.parse();

    try result.invoke();

    // Try running with:
    // demo sub "hello world" '{"name":"Jane","id":456}' '{"name":"Joan","id":789}' --worker '{"name":"John","id":123}' -i 32
    // demo sub "hello world" '{"name":"Jane","id":456}' -w '{"name":"John","id":123}' -i 12
    // demo sub "hello world" '{"name":"Jane","id":456}' -w='{"name":"John","id":123}'
    // demo
    // demo sub -h
}
