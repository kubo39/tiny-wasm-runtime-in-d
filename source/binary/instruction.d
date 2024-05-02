module binary.instruction;

import binary.types: Block;

import std.sumtype;

///
struct If
{
    ///
    Block block;
}

///
struct End {}

///
struct Return {}

///
struct LocalGet
{
    ///
    uint idx;
}

///
struct LocalSet
{
    ///
    uint idx;
}

///
struct I32Store
{
    ///
    uint align_;
    ///
    uint offset;
}

///
struct I32Const
{
    ///
    int value;
}

///
struct I32LtS {}

///
struct I32Add {}

///
struct I32Sub {}

///
struct Call
{
    ///
    uint idx;
}

alias Instruction = SumType!(
    If,
    End,
    Return,
    LocalGet,
    LocalSet,
    I32Store,
    I32Const,
    I32LtS,
    I32Add,
    I32Sub,
    Call,
);

///
bool isEndInstruction(Instruction instruction)
{
    return instruction.match!(
        (End _) => true,
        _ => false
    );
}
