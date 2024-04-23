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

struct Internal
{
    InternalFuncInst func;
}

alias FuncInst = SumType!(Internal);

struct Store
{
    FuncInst[] funcs;

    this(Module mod)
    {
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
            funcs ~= cast(FuncInst) Internal(
                InternalFuncInst(funcType, Func(locals, body.code))
            );
        }
    }
}
