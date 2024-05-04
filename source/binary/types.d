module binary.types;

import binary.instruction;

import std.sumtype;

///
struct FuncType
{
    ///
    const(ValueType[]) params;
    ///
    const(ValueType[]) results;
}

///
enum ValueType : ubyte
{
    I32 = 0x7F,
    I64 = 0x7E,
}

///
struct FunctionLocal
{
    ///
    uint typeCount;
    ///
    ValueType valueType;
}

///
struct Func
{
    ///
    uint idx;
}

alias ExportDesc = SumType!(Func);

///
struct Export
{
    ///
    string name;
    ///
    ExportDesc desc;
}

alias ImportDesc = SumType!(Func);

///
struct Import
{
    ///
    string moduleName;
    ///
    string field;
    ///
    ImportDesc desc;
}

///
struct Limits
{
    ///
    uint min;
    ///
    uint max;
}

///
struct Memory
{
    ///
    Limits limits;
}

///
struct Data
{
    ///
    uint memoryIndex;
    ///
    const(Instruction)[] offset;
    ///
    const(ubyte)[] bytes;
}

///
struct Block
{
    ///
    BlockType blockType;
}

///
struct Void {}

alias BlockType = SumType!(
    Void,
    ValueType[],
);

///
size_t resultCount(BlockType blockType)
{
    return blockType.match!(
        (Void _) => 0,
        (ValueType[] valueTypes) => valueTypes.length
    );
}
