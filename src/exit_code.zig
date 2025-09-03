const _exit = @import("std").process.exit;

pub const ExitCode = enum(u8) {
    Success = 0,
    GeneralError = 1,
    InvalidCharacter = 2,
    Overflow = 3,
    SyntaxError = 4,
    UnexpectedToken = 5,
    ArgumentNotFound = 6,
    ArgumentMissing = 7,
    NoValueSet = 8,
    NoActionDefined = 9,
    InvalidEnumValue = 10,
    InvalidJsonFormat = 11,
    MissingRequiredField = 12,
    UnknownJsonField = 13,
    UnsupportedType = 14,
    WriteFailed = 15,
    OutOfMemory = 16,
};

pub fn exit(code: ExitCode) noreturn {
    _exit(@intFromEnum(code));
}
