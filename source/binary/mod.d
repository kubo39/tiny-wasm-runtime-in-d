module binary.mod;

import binary.instruction;
import binary.leb128;
import binary.opcode;
import binary.section;
import binary.types;

import std.algorithm : each;
import std.bitmanip : read;
import std.exception : enforce;
import std.range : popFrontExactly;
import std.system : Endian;
import std.typecons : Tuple, tuple;

///
struct Module
{
    ///
    immutable ubyte[4] magic = ['\0', 'a', 's', 'm'];
    ///
    immutable uint version_ = 1;
    ///
    Memory[] memorySection;
    ///
    Data[] dataSection;
    ///
    FuncType[] typeSection;
    ///
    uint[] functionSection;
    ///
    Function[] codeSection;
    ///
    Export[] exportSection;
    ///
    Import[] importSection;
}

///
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
            const memory = decodeMemorySection(input);
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
        memorySection: memorySection,
        dataSection: dataSection,
        typeSection: typeSection,
        functionSection: functionSection,
        codeSection: codeSection,
        exportSection: exportSection,
        importSection: importSection
    );
}

private:

///
Tuple!(SectionCode, uint) decodeSectionHeader(ref const(ubyte)[] input)
{
    auto code = cast(SectionCode) input.read!ubyte();
    auto size = input.leb128!uint();
    return tuple(code, size);
}

///
Memory decodeMemorySection(ref const(ubyte)[] input)
{
    input.leb128!uint();
    auto limits = decodeLimits(input);
    return Memory(limits: limits);
}

///
Limits decodeLimits(ref const(ubyte)[] input)
{
    const flags = input.leb128!uint();
    auto min = input.leb128!uint();
    auto max = flags == 0 ? uint.max : input.leb128!uint();
    return Limits(min: min, max: max);
}

///
uint decodeExpr(ref const(ubyte)[] input)
{
    input.leb128!uint(); // i32.const
    auto offset = input.leb128!uint();
    input.leb128!uint(); // end
    return offset;
}

///
Data[] decodeDataSection(ref const(ubyte)[] input)
{
    const count = input.leb128!uint();
    Data[] data;
    foreach (_; 0..count)
    {
        auto memoryIndex = input.leb128!uint();
        auto offset = input.decodeExpr();
        auto size = input.leb128!uint();
        auto bytes = cast(ubyte[]) input[0..size];
        input.popFrontExactly(size);
        data ~= Data(
            memoryIndex: memoryIndex,
            offset: offset,
            bytes: bytes
        );
    }
    return data;
}

///
ValueType decodeValueSection(ref const(ubyte)[] input)
{
    return cast(ValueType) input.read!ubyte();
}

///
FuncType[] decodeTypeSection(ref const(ubyte)[] input)
{
    FuncType[] funcTypes;
    const count = input.leb128!uint();
    foreach (_; 0..count)
    {
        input.read!ubyte();
        uint size = input.leb128!uint();
        auto params = cast(ValueType[]) input[0..size];
        input.popFrontExactly(size);
        size = input.leb128!uint();
        auto results = cast(ValueType[]) input[0..size];
        input.popFrontExactly(size);
        funcTypes ~= FuncType(params, results);
    }
    return funcTypes;
}

///
uint[] decodeFunctionSection(ref const(ubyte)[] input)
{
    uint[] funcIdxList;
    const count = input.leb128!uint();
    foreach (_; 0..count)
    {
        const idx = input.leb128!uint();
        funcIdxList ~= idx;
    }
    return funcIdxList;
}

///
Function[] decodeCodeSection(ref const(ubyte)[] input)
{
    Function[] functions;
    const count = input.leb128!uint();
    foreach (_; 0..count)
    {
        auto size = input.leb128!uint(); // func body size
        functions ~= input.decodeFunctionBody(size);
    }
    return functions;
}

///
Function decodeFunctionBody(ref const(ubyte)[] input, ref uint remaining)
{
    Function body;
    const count = input.leb128!uint();
    remaining--;
    foreach (_; 0..count)
    {
        auto typeCount = input.leb128!uint();
        remaining--;
        auto valueType = input.decodeValueSection();
        remaining--;
        body.locals ~= FunctionLocal(typeCount, valueType);
    }

    while (remaining > 0)
    {
        auto instruction = input.decodeInstruction(remaining);
        body.code ~= instruction;
    }
    return body;
}

///
Instruction decodeInstruction(ref const(ubyte)[] input, ref uint remaining)
{
    auto op = cast(OpCode) input.read!ubyte();
    remaining--;
    switch (op)
    {
    case OpCode.If:
        auto block = input.decodeBlockSection(remaining);
        return Instruction(If(block));
    case OpCode.Return:
        return Instruction(Return());
    case OpCode.LocalGet:
        auto idx = input.leb128!uint();
        remaining--;
        return Instruction(LocalGet(idx));
    case OpCode.LocalSet:
        auto idx = input.leb128!uint();
        remaining--;
        return Instruction(LocalSet(idx));
    case OpCode.I32Store:
        auto align_ = input.leb128!uint();
        auto offset = input.leb128!uint();
        remaining -= 2;
        return Instruction(I32Store(align_, offset));
    case OpCode.I32Const:
        auto value = input.leb128!int();
        remaining--;
        return Instruction(I32Const(value));
    case OpCode.I32LtS:
        return Instruction(I32LtS());
    case OpCode.I32Add:
        return Instruction(I32Add());
    case OpCode.I32Sub:
        return Instruction(I32Sub());
    case OpCode.End:
        return Instruction(End());
    case OpCode.Call:
        auto idx = input.leb128!uint();
        remaining--;
        return Instruction(Call(idx));
    default:
        import std.format : format;
        assert(false, op.format!"invalid opcode: %d"());
    }
}

///
Block decodeBlockSection(ref const(ubyte)[] input, ref uint remaining)
{
    const mark = input.read!ubyte();
    remaining--;
    BlockType blockType;
    if (mark == 0x40)
    {
        blockType = BlockType(Void());
    }
    else
    {
        blockType = BlockType([cast(ValueType) mark]);
    }
    return Block(blockType: blockType);
}

///
Export[] decodeExportSection(ref const(ubyte)[] input)
{
    const count = input.leb128!uint();
    Export[] exports;
    foreach (_; 0..count)
    {
        string name = input.decodeName();
        const exportKind = input.read!ubyte();
        enforce(exportKind == 0x0, "unsupported export kind");
        auto idx = input.leb128!uint();
        ExportDesc desc = Func(idx);
        exports ~= Export(name, desc);
    }
    return exports;
}

///
Import[] decodeImportSection(ref const(ubyte)[] input)
{
    const count = input.leb128!uint();
    Import[] imports;
    foreach (_; 0..count)
    {
        auto moduleName = input.decodeName();
        auto field = input.decodeName();
        auto importKind = input.read!ubyte();
        enforce(importKind == 0x00, "unsupported import kind");
        auto idx = input.leb128!uint();
        ImportDesc desc = Func(idx);
        imports ~= Import(moduleName, field, desc);
    }
    return imports;
}

string decodeName(ref const(ubyte)[] input)
{
    const nameLen = input.leb128!uint();
    auto name = cast(string) input[0..nameLen];
    input.popFrontExactly(nameLen);
    return name;
}

@("decodeSimplestModule")
unittest
{
    import std.process;
    const p = executeShell(q{echo "(module)" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    assert(decodeModule(wasm) == Module());
}

@("decodeSimplestFunc")
unittest
{
    import std.process;
    const p = executeShell(q{echo "(module (func))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [{ locals: [], code: [Instruction(End())] }],
        exportSection: [],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncParams")
unittest
{
    import std.process;
    const p = executeShell(q{echo "(module (func (param i32 i64)))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{
            params: [ValueType.I32, ValueType.I64],
            results: []
        }],
        functionSection: [0],
        codeSection: [{ locals: [], code: [Instruction(End())] }],
        exportSection: [],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncLocal")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/func_local.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [{
            locals: [
                FunctionLocal(1, ValueType.I32),
                FunctionLocal(2, ValueType.I64)
            ],
            code: [Instruction(End())]
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
    const p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
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
                Instruction(LocalGet(0)),
                Instruction(LocalGet(1)),
                Instruction(I32Add()),
                Instruction(End())
            ]
        }]
        ,
        exportSection: [{
            name: "add",
            desc: ExportDesc(Func(0))
        }],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeFuncCall")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/func_call.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
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
                    Instruction(LocalGet(0)),
                    Instruction(Call(1)),
                    Instruction(End())
                ]
            },
            {
                locals: [],
                code: [
                    Instruction(LocalGet(0)),
                    Instruction(LocalGet(0)),
                    Instruction(I32Add()),
                    Instruction(End())
                ]
            }
        ]
        ,
        exportSection: [{
            name: "call_doubler",
            desc: ExportDesc(Func(0))
        }],
        importSection: []
    };
    assert(actual == expected);
}

@("decodeImport")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
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
                    Instruction(LocalGet(0)),
                    Instruction(Call(0)),
                    Instruction(End())
                ]
            }
        ]
        ,
        exportSection: [{
            name: "call_add",
            desc: ExportDesc(Func(1))
        }],
        importSection: [{
            moduleName: "env",
            field: "add",
            desc: ImportDesc(Func(0))
        }]
    };
    assert(actual == expected);
}

@("decode i32.store")
unittest
{
    import std.process;
    const p = executeShell(q{echo "(module (func (i32.store offset=4 (i32.const 4))))" | wasm-tools parse -});
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [{ params: [], results: [] }],
        functionSection: [0],
        codeSection: [
            {
                locals: [],
                code: [
                    Instruction(I32Const(4)),
                    Instruction(I32Store(
                        align_: 2,
                        offset: 4
                    )),
                    Instruction(End())
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
        const p = executeShell(q{echo "%s" | wasm-tools parse -}.format(test[0]));
        const (ubyte)[] wasm = cast(ubyte[]) p.output;
        const actual = decodeModule(wasm);
        const Module expected = {
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
            "source/fixtures/data.wat",
            [
                Data(memoryIndex: 0, offset: 0, bytes: cast(ubyte[]) "hello")
            ]
        ),
        tuple(
            "source/fixtures/memory.wat",
            [
                Data(memoryIndex: 0, offset: 0, bytes: cast(ubyte[]) "hello"),
                Data(memoryIndex: 0, offset: 5, bytes: cast(ubyte[]) "world")
            ]

        )
    ];
    foreach (test; tests)
    {
        const p = executeShell("wasm-tools parse %s".format(test[0]));
        const (ubyte)[] wasm = cast(ubyte[]) p.output;
        const actual = decodeModule(wasm);
        const Module expected = {
            memorySection: [Memory(limits: Limits(min: 1, max: uint.max))],
            dataSection: test[1]
        };
        assert(actual == expected);
    }
}

@("decode fib")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/fib.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    const actual = decodeModule(wasm);
    const Module expected = {
        magic: ['\0', 'a', 's', 'm'],
        version_: 1,
        typeSection: [
            {
                params: [ValueType.I32],
                results: [ValueType.I32]
            }
        ],
        functionSection: [0],
        codeSection: [
            {
                locals: [],
                code: [
                    Instruction(LocalGet(0)),
                    Instruction(I32Const(2)),
                    Instruction(I32LtS()),
                    Instruction(
                        If(Block(BlockType(Void())))
                    ),
                    Instruction(I32Const(1)),
                    Instruction(Return()),
                    Instruction(End()),
                    Instruction(LocalGet(0)),
                    Instruction(I32Const(2)),
                    Instruction(I32Sub()),
                    Instruction(Call(0)),
                    Instruction(LocalGet(0)),
                    Instruction(I32Const(1)),
                    Instruction(I32Sub()),
                    Instruction(Call(0)),
                    Instruction(I32Add()),
                    Instruction(Return()),
                    Instruction(End())
                ]
            }
        ]
        ,
        exportSection: [
            Export(
                name: "fib",
                desc: ExportDesc(Func(0)),
            )
        ],
        importSection: []
    };
    assert(actual == expected);
}
