#include <stdio.h>
#include <stdalign.h>
#include "mir.h"

// sort of like autotools configure - we probe the size and alignment
// of the MIR_op_t bitfield which is translated in zig as an opaque type.
// We need a structure with the same size/alignment so zig can allocate
// these objects on the stack (return, etc)

int main(void) {
    const char *format_string = 
        "// AUTO-GENERATED. Do not edit.\n"
        "pub const MIR_OP_SIZE: usize = %zu;\n"
        "pub const MIR_OP_ALIGN: usize = %zu;\n"
        ""
        "/// ABI-stable storage for C's MIR_op_t.\n"
        "/// We do not access fields from Zig; we only pass/return it by value.\n"
        "pub const MIR_op_t = extern struct {\n"
        "    _bytes: [MIR_OP_SIZE]u8 align(MIR_OP_ALIGN),\n"
        "};\n";

  printf(format_string, sizeof(MIR_op_t), alignof(MIR_op_t));
  return 0;
}
