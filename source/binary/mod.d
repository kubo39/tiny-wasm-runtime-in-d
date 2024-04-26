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
    Import[] importSection;
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
    Import[] importSection;

    while (input.length)
    {
        auto sectionHeader = decodeSectionHeader(input);
        switch (sectionHeader[0])
        {
        case SectionCode.Custom:
            // skip
            input = input[sectionHeader[1] .. $];
            break;
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
        case SectionCode.Import:
            importSection = decodeImportSection(input);
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
        exportSection,
        importSection
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
    case OpCode.Call:
        auto idx = input.leb128Uint();
        return cast(Instruction) Call(idx);
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
        string name = input.decodeName();
        const exportKind = input.read!ubyte();
        enforce(exportKind == 0x0, "unsupported export kind");
        auto idx = input.leb128Uint();
        ExportDesc desc = Func(idx);
        exports ~= Export(name, desc);
    }
    return exports;
}

Import[] decodeImportSection(ref const(ubyte)[] input)
{
    const count = input.leb128Uint();
    Import[] imports;
    foreach (_; 0..count)
    {
        auto moduleName = input.decodeName();
        auto field = input.decodeName();
        auto importKind = input.read!ubyte();
        enforce(importKind == 0x00, "unsupported import kind");
        auto idx = input.leb128Uint();
        ImportDesc desc = Func(idx);
        imports ~= Import(moduleName, field, desc);
    }
    return imports;
}

private string decodeName(ref const(ubyte)[] input)
{
    const nameLen = input.leb128Uint();
    char[] name;
    iota(nameLen).each!(_ => name ~= input.read!ubyte());
    return cast (string) name;
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
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [{ locals: [], code: [cast(Instruction) End()] }],
        exportSection: [],
        importSection: []
    };
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
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{
            params: [ValueType.I32, ValueType.I64],
            results: []
        }],
        functionSection: [0],
        codeSection: [{ locals: [], code: [cast(Instruction) End()] }],
        exportSection: [],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncLocal")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_local.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [{
            locals: [
                FunctionLocal(1, ValueType.I32),
                FunctionLocal(2, ValueType.I64)
            ],
            code: [cast(Instruction) End()]
        }],
        exportSection: [],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncAdd")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{
            params: [ValueType.I32, ValueType.I32],
            results: [ValueType.I32]
        }],
        functionSection: [0],
        codeSection: [{
            locals: [],
            code: [
                cast(Instruction) LocalGet(0),
                cast(Instruction) LocalGet(1),
                cast(Instruction) I32Add(),
                cast(Instruction) End()
            ]
        }]
        ,
        exportSection: [{
            name: "add",
            desc: cast(ExportDesc) Func(0)
        }],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncCall")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_call.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [FuncType(
            [ValueType.I32],
            [ValueType.I32]
        )],
        functionSection: [0, 0],
        codeSection: [
            {
                locals: [],
                code: [
                    cast(Instruction) LocalGet(0),
                    cast(Instruction) Call(1),
                    cast(Instruction) End()
                ]
            },
            {
                locals: [],
                code: [
                    cast(Instruction) LocalGet(0),
                    cast(Instruction) LocalGet(0),
                    cast(Instruction) I32Add(),
                    cast(Instruction) End()
                ]
            }
        ]
        ,
        exportSection: [{
            name: "call_doubler",
            desc: cast(ExportDesc) Func(0)
        }],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeImport")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{
            params: [ValueType.I32],
            results: [ValueType.I32]
        }],
        functionSection: [0],
        codeSection: [
            {
                locals: [],
                code: [
                    cast(Instruction) LocalGet(0),
                    cast(Instruction) Call(0),
                    cast(Instruction) End()
                ]
            }
        ]
        ,
        exportSection: [{
            name: "call_add",
            desc: cast(ExportDesc) Func(1)
        }],
        importSection: [{
            moduleName: "env",
            field: "add",
            desc: cast(ImportDesc) Func(0)
        }]
    };
    assert(actual == expected);
}
