# cli-parser

A flexible and type-safe command-line argument parser for Zig applications. Build rich CLI tools with nested commands, typed options/arguments, flags, JSON-typed values, and defaults.

## Features

* Type-safe parsing (generic `Option(T)` / `Argument(T)` constructors)
* Nested commands / subcommands with inherited context
* Short & long options (`-i`, `--int`), boolean flags, positional arguments
* JSON parsing for struct types (e.g. `--worker '{"name":"A","id":1}'`)
* Arity support and default values (single or multiple)
* Configurable parsing behavior (unknown options, delimiters, etc.)

## Usage

See the [examples](./examples) directory for usage examples.

### Argument and Option Creation

Arguments and options are created using the `Argument` and `Option` structs with their respective configuration structs:

```zig
const int_arg_config = ArgConfig{
    .name = "int_arg",
    .description = "An integer argument",
    .required = true,
    .type = i32,
};
const int_arg = Argument(int_arg_config).init(allocator);
```

```zig
const str_opt_config = OptConfig{
    .name = "str_opt", // either long name or short name must be provided, but one is enough
    .short = 's',
    .description = "A string option",
    .required = false,
    .default_value = "default",
    .type = []const u8,
};

const str_opt = Option(str_opt_config).init(allocator);
```

### Command Creation
Commands are created using the `Command` function:

```zig
const root_cmd = try Command.init("root, "A root command", allocator);

_ = root_cmd.withOption(str_opt_config, str_opt)
    .withArgument(int_arg_config, int_arg)
```

You can also create subcommands:

```zig
const sub_cmd = try Command.init("sub", "A subcommand", allocator);
_ = root_cmd.withSubcommand(sub_cmd);
```

Create a function for the command to execute when invoked:

```zig
const action: ActionFn = struct {
    pub fn call(ctx: ActionContext) !void {
        const str_value = try ctx.getOption([]const u8, "str_opt") catch unreachable; // has default
        const int_value = try ctx.getArgument(i32, "int_arg") catch unreachable; // required
        std.debug.print("str_opt: {}, int_arg: {}\n", .{str_value, int_value});
    }
}.call;
```

Then set the action for the command:

```zig
_ = sub_cmd.withAction(action);
```

### Parser Configuration

The parser can be configured using the `ParserConfig` struct:

```zig
const parser_config = ParserConfig{
    /// Whether to allow unknown options (default: false)
    allow_unknown_options: bool = false,
    /// Whether to treat `--` as the end of options (default: true)
    double_hyphen_delimiter: bool = true,
    /// Whether to allow options after positional arguments (default: false)
    allow_options_after_args: bool = false,
};
```

Create the parser:

```zig
const parser = Parser(parser_config).init(root_cmd, allocator);
```

Parse the command-line arguments:

```zig
const result = try parser.parse();
```

Finally, invoke the parsed action:

```zig
try result.invoke();
```

### How to Import

Add cli-parser to your project using `zig fetch`:

```bash
zig fetch --save git+https://github.com/arnon4/cli-parser
```

Then add it to your `build.zig`:

```zig
const parser_dep = b.dependency("cli-parser", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("parser", parser_dep.module("parser"));
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
