module execution.runtime;

import binary.instruction;
import binary.mod;
import binary.types;

import execution.store;
import execution.value;

import std.exception : enforce;
import std.range;
import std.sumtype;
import std.typecons;

struct Frame
{
    size_t pc;
    size_t sp;
    Instruction[] insts;
    size_t arity;
    Value[] locals;

    @disable this(ref Frame);
}

struct Runtime
{
private:
    Store store;
    Value[] stack;
    Frame*[] callStack;

    void execute()
    {
        while (this.callStack.length)
        {
            auto frame = this.callStack.back;
            frame.pc++;
            Instruction inst = frame.insts[frame.pc];

            inst.match!(
                (LocalGet localGet) {
                    Value value = frame.locals[localGet.idx];
                    this.stack ~= value;
                },
                (End _) {
                    auto frame = this.callStack.back;
                    this.callStack.popBack();
                    stack_unwind(this.stack, frame.sp, frame.arity);
                },
                (I32Add _) {
                    // pop
                    auto right = this.stack.back;
                    this.stack.popBack();
                    auto left = this.stack.back;
                    this.stack.popBack();

                    Value result = left.match!(
                        (I32 lhs) => right.match!(
                                (I32 rhs) => cast(Value) (lhs + rhs),
                                (I64 _) => assert(false, "type mismatch")
                            ),
                        (I64 lhs) => right.match!(
                                (I32 _) => assert(false, "type mismatch"),
                                (I64 rhs) => cast(Value) (lhs + rhs)
                            )
                    );
                    this.stack ~= result;
                },
                _ => assert(false)
            );
        }
    }

    Nullable!Value invokeInternal(InternalFuncInst func)
    {
        const bottom = this.stack.length - func.funcType.params.length;
        Value[] locals = this.stack[bottom..$];
        this.stack = this.stack[0..bottom];

        foreach (local; func.code.locals)
        {
            final switch (local)
            {
            case ValueType.I32:
                locals ~= cast(Value) I32(0);
                break;
            case ValueType.I64:
                locals ~= cast(Value) I64(0);
                break;
            }
        }

        const arity = func.funcType.results.length;
        auto frame = new Frame(
            -1,
            this.stack.length,
            func.code.body,
            arity,
            locals
        );
        this.callStack ~= frame;
        execute();

        if (arity > 0)
        {
            auto value = stack.back;
            stack.popBack();
            return nullable(value);
        }
        return Nullable!Value.init;
    }

public:
    static Runtime instantiate(ref const(ubyte)[] wasm)
    {
        auto mod = decodeModule(wasm);
        auto store = Store(mod);
        return Runtime(store);
    }

    Nullable!Value call(string name, Value[] args)
    {
        ExportInst* p = name in this.store.moduleInst.exports;
        enforce(p !is null, "not found export function");
        auto idx = (*p).desc.match!(
            (binary.types.Func func) => func.idx
        );
        auto funcInst = this.store.funcs[idx];
        foreach (arg; args)
        {
            this.stack ~= arg;
        }
        return funcInst.match!(
            (Internal internal) => invokeInternal(internal.func),
        );
    }
}

private void stack_unwind(ref Value[] stack, size_t sp, size_t arity)
{
    if (arity > 0)
    {
        auto value = stack.back;
        stack.popBack();
        stack = stack[0..sp];
        stack ~= value;
    }
    else
    {
        stack = stack[0..sp];
    }
}

@("executeI32Add")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const tests = [
        [2, 3, 5],
        [10, 5, 15],
        [1, 1, 2]
    ];
    foreach (test; tests)
    {
        Value[] args = [cast(Value) I32(test[0]), cast(Value) I32(test[1])];
        const Nullable!Value result = runtime.call("add", args);
        result.get().match!(
            (I32 actual) => assert(actual.i == test[2]),
            _ => assert(false)
        );
    }
    
}

@("not found export function")
unittest
{
    import std.exception;
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    assertThrown(runtime.call("foooo", []));
}
