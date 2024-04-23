module binary.instruction;

import std.sumtype;

struct End {}
struct LocalGet { uint index; }
struct I32Add {}

alias Instruction = SumType!(
    End,
    LocalGet,
    I32Add
);
