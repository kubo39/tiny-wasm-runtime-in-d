module execution.store;

import binary.instruction;
import binary.mod;
import binary.types;

import std.range : zip;
import std.sumtype;

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

struct Store
{
    FuncInst[] funcs;
    ModuleInst moduleInst;

    this(Module mod)
    {
        foreach (imported; mod.importSection)
        {
            auto moduleName = imported.moduleName;
            auto field = imported.field;
            auto funcType = imported.desc.match!(
                (binary.types.Func func) => mod.typeSection[func.idx],
            );
            FuncInst func = ExternalFuncInst(
                moduleName,
                field,
                funcType
            );
            funcs ~= func;
        }

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
    }
}
