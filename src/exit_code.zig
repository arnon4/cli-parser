const _exit = @import("std").process.exit;

pub const ExitCode = enum(u8) {
    Success = 0,
    GeneralError,
    InvalidCharacter,
    Overflow,
    SyntaxError,
    UnexpectedToken,
    ArgumentNotFound,
    ArgumentMissing,
    NoValueSet,
    NoActionDefined,
    InvalidEnumValue,
    InvalidJsonFormat,
    MissingRequiredField,
    UnknownJsonField,
    UnsupportedType,
    WriteFailed,
    OutOfMemory,
    InvalidConfiguration,
};

pub fn exit(code: ExitCode) noreturn {
    _exit(@intFromEnum(code));
}
