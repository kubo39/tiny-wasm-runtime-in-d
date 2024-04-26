module binary.instruction;

import std.sumtype;

struct End {}
struct LocalGet { uint idx; }
struct LocalSet { uint idx; }
struct I32Const { int value; }
struct I32Add {}
struct Call { uint idx; }

alias Instruction = SumType!(
    End,
    LocalGet,
    LocalSet,
    I32Const,
    I32Add,
    Call,
);

bool isEndInstruction(Instruction instruction)
{
    return instruction.match!(
        (End _) => true,
        _ => false
    );
}
