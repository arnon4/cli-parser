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

    // Create arguments
    var str_arg = try Argument([]const u8).init("input", "A string argument", false, allocator);
    defer str_arg.deinit();

    // Create flags
    var flag = try Flag.init("Enable verbose output", false, allocator);
    _ = flag.withName("verbose").withShort('v');

    // Create action function
    const action: ActionFn = struct {
        fn call(context: ActionContext) anyerror!void {
            // access options, flags, and arguments via ActionContext
            const int_value = context.getOption(i32, "int") catch 42;
            const flag_value = context.getFlag("verbose");
            const arg_value = context.getArgument([]const u8, "input") catch "no input";

            std.debug.print("Command executed successfully\n", .{});
            std.debug.print("Integer option value: {d}\n", .{int_value});
            std.debug.print("Verbose flag value: {}\n", .{flag_value});
            std.debug.print("Input argument value: {s}\n", .{arg_value});
        }
    }.call;

    // Create command
    const cmd = try Command.init("demo", "A demo command", allocator);
    defer cmd.deinit();

    // Register options, arguments, flags, and action
    _ = cmd.withOption(i32, int_opt)
        .withArgument([]const u8, str_arg)
        .withFlag(flag)
        .withAction(action);

    // Create parser
    var parser = Parser(.{}).init(cmd, allocator);
    defer parser.deinit();

    // Parse command line arguments and get both command and context
    const result = try parser.parse();

    // Execute the command action with the populated context
    try result.invoke();
}
