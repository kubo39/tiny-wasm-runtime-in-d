module binary.mod;

import binary.instruction;
import binary.opcode;
import binary.section;
import binary.types;

import std.algorithm : each;
import std.bitmanip : read;
import std.exception : enforce;
import std.range : iota;
import std.system : Endian;
import std.typecons : Tuple, tuple;

struct Module
{
    ubyte[4] magic = ['\0', 'a', 's', 'm'];
    uint version_ = 1;
    FuncType[] typeSection;
    uint[] functionSection;
    Function[] codeSection;
    Export[] exportSection;
}

Module decodeModule(ref const(ubyte)[] input)
{
    enforce(input.length >= 8);
    enforce('\0' == input.read!ubyte());
    enforce('a' == input.read!ubyte());
    enforce('s' == input.read!ubyte());
    enforce('m' == input.read!ubyte());
    auto version_ = input.read!(uint, Endian.littleEndian)();
    enforce(version_ == 1);

    FuncType[] typeSection;
    uint[] functionSection;
    Function[] codeSection;
    Export[] exportSection;

    while (input.length)
    {
        auto sectionHeader = decodeSectionHeader(input);
        switch (sectionHeader[0])
        {
        case SectionCode.Type:
            typeSection = decodeTypeSection(input);
            break;
        case SectionCode.Function:
            functionSection = decodeFunctionSection(input);
            break;
        case SectionCode.Code:
            codeSection = decodeCodeSection(input);
            break;
        case SectionCode.Export:
            exportSection = decodeExportSection(input);
            break;
        default:
            assert(false);
        }
    }

    return Module(
        ['\0', 'a', 's', 'm'],
        version_,
        typeSection,
        functionSection,
        codeSection,
        exportSection
    );
}

private uint leb128Uint(ref const(ubyte)[] input)
{
    uint val = 0;
    uint shift = 0;
    while (true)
    {
        ubyte b = input.read!ubyte();
        val |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
    }
    return val;
}

Tuple!(SectionCode, uint) decodeSectionHeader(ref const(ubyte)[] input)
{
    auto code = cast(SectionCode) input.read!ubyte();
    uint size = input.leb128Uint();
    return tuple(code, size);
}

ValueType decodeValueSection(ref const(ubyte)[] input)
{
    return cast(ValueType) input.read!ubyte();
}

FuncType[] decodeTypeSection(ref const(ubyte)[] input)
{
    FuncType[] funcTypes;
    const count = input.leb128Uint();
    foreach (_; 0..count)
    {
        input.read!ubyte();
        uint size = input.leb128Uint();
        ValueType[] params;
        iota(size).each!(_ => params ~= input.decodeValueSection());
        size = input.leb128Uint();
        ValueType[] results;
        iota(size).each!(_ => results ~= input.decodeValueSection());
        funcTypes ~= FuncType(params, results);
    }
    return funcTypes;
}

uint[] decodeFunctionSection(ref const(ubyte)[] input)
{
    uint[] funcIdxList;
    uint count = input.leb128Uint();
    foreach (_; 0..count)
    {
        uint idx = input.leb128Uint();
        funcIdxList ~= idx;
    }
    return funcIdxList;
}

Function[] decodeCodeSection(ref const(ubyte)[] input)
{
    Function[] functions;
    const count = input.leb128Uint();
    foreach (_; 0..count)
    {
        uint size = input.leb128Uint();
        functions ~= input.decodeFunctionBody();
    }
    return functions;
}

Function decodeFunctionBody(ref const(ubyte)[] input)
{
    Function body;
    const count = input.leb128Uint();
    foreach (_; 0..count)
    {
        auto typeCount = input.leb128Uint();
        auto valueType = input.decodeValueSection();
        body.locals ~= FunctionLocal(typeCount, valueType);
    }

    // FIXME: 命令だけconsumeするようにしないといけない
    while (input.length)
    {
        auto instruction = input.decodeInstruction();
        body.code ~= instruction;
        if (instruction.isEndInstruction())
        {
            break;
        }
    }
    return body;
}


Instruction decodeInstruction(ref const(ubyte)[] input)
{
    auto op = cast(OpCode) input.read!ubyte();
    switch (op)
    {
    case OpCode.LocalGet:
        auto idx = input.leb128Uint();
        return cast(Instruction) LocalGet(idx);
    case OpCode.I32Add:
        return cast(Instruction) I32Add();
    case OpCode.End:
        return cast(Instruction) End();
    default:
        assert(false, "invalid opcode");
    }
}

Export[] decodeExportSection(ref const(ubyte)[] input)
{
    const count = input.leb128Uint();
    Export[] exports;
    foreach (_; 0..count)
    {
        const nameLen = input.leb128Uint();
        ubyte[] name;
        iota(nameLen).each!(_ => name ~= input.read!ubyte());
        const exportKind = input.read!ubyte();
        enforce(exportKind == 0x0, "unsupported export kind");
        auto idx = input.leb128Uint();
        ExportDesc desc = Func(idx);
        exports ~= Export(cast(string) name, desc);
    }
    return exports;
}

@("decodeSimplestModule")
unittest
{
    import std.process;
    auto p = executeShell(q{echo "(module)" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    assert(decodeModule(wasm) == Module());
}

@("decodeSimplestFunc")
unittest
{
    import std.process;
    auto p = executeShell(q{echo "(module (func))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    auto expected = Module(
        ['\0', 'a', 's', 'm'],
        1,
        [FuncType([], [])],
        [0],
        [Function([], [cast(Instruction) End()])],
        []
    );
    assert(actual == expected);
}

@("decodeFuncParams")
unittest
{
    import std.process;
    auto p = executeShell(q{echo "(module (func (param i32 i64)))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Instruction end = End();
    auto expected = Module(
        ['\0', 'a', 's', 'm'],
        1,
        [FuncType([ValueType.I32, ValueType.I64], [])],
        [0],
        [Function([], [cast(Instruction) End()])],
        []
    );
    assert(actual == expected);
}

@("decodeFuncLocal")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_local.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    auto expected = Module(
        ['\0', 'a', 's', 'm'],
        1,
        [FuncType([], [])],
        [0],
        [Function(
            [
                FunctionLocal(1, ValueType.I32),
                FunctionLocal(2, ValueType.I64)
            ],
            [cast(Instruction) End()]
        )],
        []
    );
    assert(actual == expected);
}

@("decodeFuncAdd")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    auto expected = Module(
        ['\0', 'a', 's', 'm'],
        1,
        [FuncType(
            [ValueType.I32, ValueType.I32],
            [ValueType.I32]
        )],
        [0],
        [Function(
            [],
            [
                cast(Instruction) LocalGet(0),
                cast(Instruction) LocalGet(1),
                cast(Instruction) I32Add(),
                cast(Instruction) End()
            ]
        )]
        ,
        [Export(
            "add",
            cast(ExportDesc) Func(0)
        )]
    );
    assert(actual == expected);
}
