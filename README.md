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

See the [examples](./examples) directory for usage examples. Parser configuration has the following options:

```zig
const ParserConfig = struct {
    /// Whether to allow unknown options (default: false)
    allow_unknown_options: bool = false,
    /// Whether to treat `--` as the end of options (default: true)
    double_hyphen_delimiter: bool = true,
    /// Whether to allow options after positional arguments (default: false)
    allow_options_after_args: bool = false,
};
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
