pub const c = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("mir.h");
    @cInclude("mir-gen.h");
    @cInclude("mir2c/mir2c.h");
    @cInclude("c2mir/c2mir.h");
});
