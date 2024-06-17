pub const OpCode = enum(u8) {
    push_null = 2,
    return_value = 83,
    load_const = 100,
    load_name = 101,
    return_const = 121,
    @"resume" = 151,
    call = 171,
};
