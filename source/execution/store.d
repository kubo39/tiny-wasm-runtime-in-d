module execution.store;

import binary.instruction;
import binary.mod;
import binary.types;

import std.bitmanip : write;
import std.exception : enforce;
import std.range : zip;
import std.sumtype;

///
enum uint PAGESIZE = 65_536;

///
struct Func
{
    ///
    const(ValueType)[] locals;
    ///
    const(Instruction)[] body;
}

///
struct InternalFuncInst
{
    ///
    FuncType funcType;
    ///
    Func code;
}

///
struct ExternalFuncInst
{
    ///
    string moduleName;
    ///
    string func;
    ///
    FuncType funcType;
}

alias FuncInst = SumType!(
    InternalFuncInst,
    ExternalFuncInst
);

///
struct ExportInst
{
    ///
    string name;
    ///
    ExportDesc desc;
}

///
struct ModuleInst
{
    ///
    const(ExportInst)[string] exports;
}

///
struct MemoryInst
{
    ///
    ubyte[] data;
    ///
    uint max;
}

///
struct Store
{
    ///
    const(FuncInst)[] funcs;
    ///
    ModuleInst moduleInst;
    ///
    MemoryInst[] memories;

    ///
    this(Module mod)
    {
        import std.algorithm : map;
        import std.array : array;
        funcs = mod.importSection.map!((imported) {
            return FuncInst(ExternalFuncInst(
                imported.moduleName,
                imported.field,
                imported.desc.match!(
                   (binary.types.Func func) => mod.typeSection[func.idx]
                )
            ));
        }).array;

        const funcTypeIdxs = mod.functionSection;
        foreach (body, idx; mod.codeSection.zip(funcTypeIdxs))
        {
            const funcType = mod.typeSection[idx];
            const(ValueType)[] locals;
            foreach (local; body.locals)
            {
                foreach (_; 0..local.typeCount)
                {
                    locals ~= local.valueType;
                }
            }
            funcs ~= FuncInst(InternalFuncInst(
                funcType: funcType,
                code: Func(
                    locals: locals,
                    body: body.code
                )
            ));
        }

        ExportInst[string] exports;
        foreach(exported; mod.exportSection)
        {
            const exportInst = ExportInst(
                name: exported.name,
                desc: exported.desc
            );
            exports[exported.name] = exportInst;
        }
        moduleInst = ModuleInst(exports);

        foreach (memory; mod.memorySection)
        {
            auto min = memory.limits.min * PAGESIZE;
            memories ~= MemoryInst(
                data: new ubyte[min],
                max: memory.limits.max
            );
        }

        foreach (segment; mod.dataSection)
        {
            auto memory = memories[segment.memoryIndex];
            const offset = segment.offset[$-1].match!(
                (I32Const i32const) => size_t(i32const.value),
                _ => enforce(false, "unexpected instrcution for offset")
            );
            auto bytes = segment.bytes;
            enforce(
                offset + bytes.length <= memory.data.length,
                "data is too large to fit in memory"
            );
            memory.data[offset..(offset+bytes.length)] = bytes;
        }
    }
}

@("init momory")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/memory.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto mod = decodeModule(wasm);
    auto store = Store(mod);
    assert(store.memories.length == 1);
    assert(store.memories[0].data.length == 65_536);
    assert(store.memories[0].data[0..5] == "hello");
    assert(store.memories[0].data[5..10] == "world");
}
