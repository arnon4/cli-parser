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
        .withDefault(42);

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
    var struct_arg = try Argument(worker_struct).init("worker_arg", "A worker struct argument", false, allocator);
    defer struct_arg.deinit();

    // Create flags
    var flag = try Flag.init("Enable verbose output", false, allocator);
    _ = flag.withName("verbose").withShort('v');

    // Create action function
    const action: ActionFn = struct {
        fn call(context: ActionContext) !void {
            std.debug.print("Sub command action called!\n", .{});

            // Get the worker option (JSON struct)
            if (context.getOption(worker_struct, "worker")) |worker| {
                std.debug.print("Worker from option: name={s}, id={d}\n", .{ worker.name, worker.id });
            }

            // Get the string argument (by name)
            if (context.getArgument([]const u8, "input")) |input| {
                std.debug.print("String argument: {s}\n", .{input});
            }

            // Get the struct argument (by name, JSON struct)
            if (context.getArgument(worker_struct, "worker_arg")) |worker_arg| {
                std.debug.print("Worker from argument: name={s}, id={d}\n", .{ worker_arg.name, worker_arg.id });
            }

            std.debug.print("Action completed successfully!\n", .{});
        }
    }.call;

    // Create command
    const cmd = try Command.init("demo", "A demo command", allocator);
    defer cmd.deinit();

    // Create subcommand
    const sub_cmd = try Command.init("sub", "A subcommand", allocator);
    defer sub_cmd.deinit();

    // Register options, arguments, flags, and action
    _ = try sub_cmd.withOption(worker_struct, worker_opt);
    _ = try sub_cmd.withArgument([]const u8, str_arg);
    _ = try sub_cmd.withArgument(worker_struct, struct_arg);
    _ = sub_cmd.withAction(action);

    _ = try cmd.withOption(i32, int_opt);
    _ = try cmd.withFlag(flag);

    // Register the subcommand
    _ = try cmd.withSubcommand(sub_cmd);

    // Create parser
    var parser = Parser.init(cmd, allocator);

    // Parse command line arguments and get both command and context
    var result = try parser.parseWithContext();
    defer result.context.deinit();

    // Execute the command action with the populated context
    try result.command.execute(result.context);
}
