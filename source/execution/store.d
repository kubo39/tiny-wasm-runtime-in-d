module execution.store;

import binary.instruction;
import binary.mod;
import binary.types;

import std.range : zip;
import std.sumtype;

enum uint PAGESIZE = 65536;

struct Func
{
    ValueType[] locals;
    Instruction[] body;
}

struct InternalFuncInst
{
    FuncType funcType;
    Func code;
}

struct ExternalFuncInst
{
    string moduleName;
    string func;
    FuncType funcType;
}

alias FuncInst = SumType!(
    InternalFuncInst,
    ExternalFuncInst
);

struct ExportInst
{
    string name;
    ExportDesc desc;
}

struct ModuleInst
{
    ExportInst[string] exports;
}

struct MemoryInst
{
    ubyte[] data;
    uint max;
}

struct Store
{
    FuncInst[] funcs;
    ModuleInst moduleInst;
    MemoryInst[] memories;

    this(Module mod)
    {
        import std.algorithm : map;
        import std.array : array;
        funcs = mod.importSection.map!((imported) {
            return cast(FuncInst) ExternalFuncInst(
                imported.moduleName,
                imported.field,
                imported.desc.match!(
                   (binary.types.Func func) => mod.typeSection[func.idx]
                )
            );
        }).array;

        auto funcTypeIdxs = mod.functionSection;
        foreach (body, idx; mod.codeSection.zip(funcTypeIdxs))
        {
            auto funcType = mod.typeSection[idx];
            ValueType[] locals;
            foreach (local; body.locals)
            {
                foreach (_; 0..local.typeCount)
                {
                    locals ~= local.valueType;
                }
            }
            funcs ~= cast(FuncInst) InternalFuncInst(funcType, Func(locals, body.code));
        }

        ExportInst[string] exports;
        foreach(exported; mod.exportSection)
        {
            ExportInst exportInst = ExportInst(
                exported.name,
                exported.desc
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
    }
}
