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
    Memory[] memorySection;
    Data[] dataSection;
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

    Memory[] memorySection;
    Data[] dataSection;
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
        case SectionCode.Memory:
            auto memory = decodeMemorySection(input);
            memorySection = [memory];
            break;
        case SectionCode.Data:
            dataSection = decodeDataSection(input);
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
        memorySection,
        dataSection,
        typeSection,
        functionSection,
        codeSection,
        exportSection,
        importSection
    );
}

alias leb128Uint = leb128!uint;
alias leb128Int = leb128!int;

private uint leb128(T)(ref const(ubyte)[] input)
    if (is(T == int) || is(T == uint))
{
    T val = 0;
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

Memory decodeMemorySection(ref const(ubyte)[] input)
{
    input.leb128Uint();
    auto limits = decodeLimits(input);
    return Memory(limits: limits);
}

Limits decodeLimits(ref const(ubyte)[] input)
{
    const flags = input.leb128Uint();
    auto min = input.leb128Uint();
    auto max = flags == 0 ? uint.max : input.leb128Uint();
    return Limits(min: min, max: max);
}

uint decodeExpr(ref const(ubyte)[] input)
{
    input.leb128Uint(); // i32.const
    auto offset = input.leb128Uint();
    input.leb128Uint(); // end
    return offset;
}

Data[] decodeDataSection(ref const(ubyte)[] input)
{
    const count = input.leb128Uint();
    Data[] data;
    foreach (_; 0..count)
    {
        auto memoryIndex = input.leb128Uint();
        auto offset = input.decodeExpr();
        auto size = input.leb128Uint();
        ubyte[] init;
        iota(size).each!(_ => init ~= input.read!ubyte());
        data ~= Data(
            memoryIndex: memoryIndex,
            offset: offset,
            init: init
        );
    }
    return data;
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
    case OpCode.LocalSet:
        auto idx = input.leb128Uint();
        return cast(Instruction) LocalSet(idx);
    case OpCode.I32Store:
        auto align_ = input.leb128Uint();
        auto offset = input.leb128Uint();
        return cast(Instruction) I32Store(align_, offset);
    case OpCode.I32Const:
        auto value = input.leb128Int();
        return cast(Instruction) I32Const(value);
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

@("decode i32.store")
unittest
{
    import std.process;
    auto p = executeShell(q{echo "(module (func (i32.store offset=4 (i32.const 4))))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto actual = decodeModule(wasm);
    Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [
            {
                locals: [],
                code: [
                    cast(Instruction) I32Const(4),
                    cast(Instruction) I32Store(
                        align_: 2,
                        offset: 4
                    ),
                    cast(Instruction) End()
                ]
            }
        ]
        ,
        exportSection: [],
        importSection: []
    };
    assert(actual == expected);
}

@("decode memory")
unittest
{
    import std.format;
    import std.process;
    import std.typecons;
    const tests = [
        tuple("(module (memory 1))", Limits(min: 1, max: uint.max)),
        tuple("(module (memory 1 2))", Limits(min: 1, max: 2))
    ];
    foreach (test; tests)
    {
        auto p = executeShell(q{echo "%s" | wasm-tools parse -}.format(test[0]));
        const (ubyte)[] wasm = cast(ubyte[]) p.output;
        auto actual = decodeModule(wasm);
        Module expected = {
            memorySection: [Memory(limits: test[1])]
        };
        assert(actual == expected);
    }
}

@("decode data")
unittest
{
    import std.format;
    import std.process;
    import std.typecons;
    auto tests = [
        tuple(
            "source/fixtures/decode_data1.wat",
            [
                Data(memoryIndex: 0, offset: 0, init: cast(ubyte[]) "hello")
            ]
        ),
        tuple(
            "source/fixtures/decode_data2.wat",
            [
                Data(memoryIndex: 0, offset: 0, init: cast(ubyte[]) "hello"),
                Data(memoryIndex: 0, offset: 5, init: cast(ubyte[]) "world")
            ]

        )
    ];
    foreach (test; tests)
    {
        auto p = executeShell("wasm-tools parse %s".format(test[0]));
        const (ubyte)[] wasm = cast(ubyte[]) p.output;
        auto actual = decodeModule(wasm);
        Module expected = {
            memorySection: [Memory(limits: Limits(min: 1, max: uint.max))],
            dataSection: test[1]
        };
        assert(actual == expected);
    }
}
