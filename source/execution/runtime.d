module execution.runtime;

import binary.instruction;
import binary.mod;
import binary.types;

import execution.store;
import execution.value;
import execution.wasi : WasiSnapshotPreview1;

import std.sumtype;
import std.typecons : Nullable, nullable;

private alias ImportFunc = Nullable!Value delegate(ref Store, Value[]);
private alias Import = ImportFunc[string][string];

///
struct Runtime
{
private:
    import std.bitmanip : write;
    import std.exception : enforce;
    import std.range : back, popBack, popBackN;
    import std.stdio;
    import std.system : Endian;

    Store store;
    Value[] stack;
    Frame*[] callStack;
    Import import_;
    Nullable!WasiSnapshotPreview1 wasi;

    struct Frame
    {
        ptrdiff_t pc;
        size_t sp;
        const(Instruction)[] insts;
        size_t arity;
        Label[] labels;
        Value[] locals;

        @disable this(ref Frame);
    }

    void execute()
    {
        while (this.callStack.length)
        {
            auto frame = this.callStack.back;
            frame.pc++;
            const inst = frame.insts[frame.pc];

            inst.match!(
                (binary.instruction.If _if) {
                    enforce(this.stack.length, "not found value in the stack");
                    const Value cond = this.stack.back;
                    this.stack.popBack();
                    if (cond == Value(I32(0)))
                    {
                        frame.pc = ptrdiff_t(getEndAddress(frame.insts, frame.pc));
                    }
                    auto label = Label(
                        kind: LabelKind(execution.value.If()),
                        pc: size_t(frame.pc),
                        sp: this.stack.length,
                        arity: _if.block.blockType.resultCount
                    );
                    frame.labels ~= label;
                },
                (LocalGet localGet) {
                    Value value = frame.locals[localGet.idx];
                    this.stack ~= value;
                },
                (LocalSet localSet) {
                    const value = this.stack.back;
                    this.stack.popBack();
                    frame.locals[localSet.idx] = value;
                },
                (Return _) {
                    if (frame.labels.length)
                    {
                        const label = frame.labels.back;
                        frame.labels.popBack();
                        frame.pc = ptrdiff_t(label.pc);
                        stack_unwind(this.stack, label.sp, label.arity);
                    }
                    else
                    {
                        auto _frame = this.callStack.back;
                        this.callStack.popBack();
                        stack_unwind(this.stack, _frame.sp, _frame.arity);
                    }
                },
                (End _) {
                    auto frame = this.callStack.back;
                    this.callStack.popBack();
                    stack_unwind(this.stack, frame.sp, frame.arity);
                },
                (I32Store i32store) {
                    const value_ = this.stack.back;
                    this.stack.popBack();
                    const valueAddr = this.stack.back;
                    this.stack.popBack();
                    const addr = cast(size_t) valueAddr.match!(
                        (I32 value) => value.i,
                        _ => assert(false)
                    );
                    const offset = cast(size_t) i32store.offset;
                    const at = addr + offset;
                    auto memory = this.store.memories[0];
                    const int value = value_.match!(
                        (I32 i32) => i32.i,
                        _ => assert(false)
                    );
                    memory.data.write!(int, Endian.littleEndian)(value, at);
                },
                (I32Const i32const) {
                    this.stack ~= Value(I32(i32const.value));
                },
                (I32Add _) {
                    // pop
                    const right = this.stack.back;
                    this.stack.popBack();
                    const left = this.stack.back;
                    this.stack.popBack();

                    Value result = left.match!(
                        (I32 lhs) => right.match!(
                                (I32 rhs) => Value(lhs + rhs),
                                (I64 _) => assert(false, "type mismatch")
                            ),
                        _ => assert(false, "type mismatch")
                    );
                    this.stack ~= result;
                },
                (I32Sub _) {
                    // pop
                    const right = this.stack.back;
                    this.stack.popBack();
                    const left = this.stack.back;
                    this.stack.popBack();

                    Value result = left.match!(
                        (I32 lhs) => right.match!(
                                (I32 rhs) => Value(lhs - rhs),
                                (I64 _) => assert(false, "type mismatch")
                            ),
                        _ => assert(false, "type mismatch")
                    );
                    this.stack ~= result;
                },
                (I32LtS _) {
                    // pop
                    const right = this.stack.back;
                    this.stack.popBack();
                    const left = this.stack.back;
                    this.stack.popBack();

                    Value result = left.match!(
                        (I32 lhs) => right.match!(
                                (I32 rhs) => Value(I32(lhs < rhs)),
                                (I64 _) => assert(false, "type mismatch")
                            ),
                        _ => assert(false, "type mismatch")
                    );
                    this.stack ~= result;
                },
                (Call call) {
                    auto func = this.store.funcs[call.idx];
                    func.match!(
                        (InternalFuncInst func) => pushFrame(func),
                        (ExternalFuncInst func) {
                            Nullable!Value value = invokeExternal(func);
                            if (!value.isNull)
                            {
                                this.stack ~= value.get;
                            }
                        }
                    );
                }
            );
        }
    }

    void pushFrame(InternalFuncInst func)
    {
        const bottom = this.stack.length - func.funcType.params.length;
        Value[] locals = this.stack[bottom..$];
        this.stack.popBackN(this.stack.length - bottom);

        foreach (local; func.code.locals)
        {
            final switch (local)
            {
            case ValueType.I32:
                locals ~= Value(I32(0));
                break;
            case ValueType.I64:
                locals ~= Value(I64(0));
                break;
            }
        }

        const arity = func.funcType.results.length;
        auto frame = new Frame(
            pc: -1,
            sp: this.stack.length,
            insts: func.code.body,
            arity: arity,
            labels: [],
            locals: locals
        );
        this.callStack ~= frame;
    }

    Nullable!Value invokeInternal(InternalFuncInst func)
    {
        const arity = func.funcType.results.length;
        pushFrame(func);

        execute();

        if (arity > 0)
        {
            auto value = stack.back;
            stack.popBack();
            return nullable(value);
        }
        return Nullable!Value.init;
    }

    Nullable!Value invokeExternal(ExternalFuncInst func)
    {
        const bottom = this.stack.length - func.funcType.params.length;
        Value[] args = this.stack[bottom..$];
        this.stack.popBackN(this.stack.length - bottom);
        if (func.moduleName == "wasi_snapshot_preview1")
        {
            if (!this.wasi.isNull)
            {
                return this.wasi.get.invoke(this.store, func.func, args);
            }
        }
        const mod = func.moduleName in this.import_;
        enforce(mod !is null, "not found module");
        const importFunc = func.func in *mod;
        enforce(importFunc !is null, "not found function");
        return (*importFunc)(this.store, args);
    }

public:
    ///
    static Runtime instantiate(const(ubyte)[] wasm)
    {
        auto mod = decodeModule(wasm);
        auto store = Store(mod);
        return Runtime(store: store);
    }

    ///
    static Runtime instantiate(const(ubyte)[] wasm, ref WasiSnapshotPreview1 wasi)
    {
        auto mod = decodeModule(wasm);
        auto store = Store(mod);
        return Runtime(
            store: store,
            wasi: nullable(wasi)
        );
    }

    ///
    void addImport(string moduleName, string funcName, ImportFunc func)
    {
        this.import_[moduleName][funcName] = func;
    }

    ///
    Nullable!Value call(string name, Value[] args)
    {
        const ExportInst* p = name in this.store.moduleInst.exports;
        enforce(p !is null, "not found export function");
        const idx = (*p).desc.match!(
            (binary.types.Func func) => func.idx
        );
        const funcInst = this.store.funcs[idx];
        foreach (arg; args)
        {
            this.stack ~= arg;
        }
        return funcInst.match!(
            (InternalFuncInst func) => invokeInternal(func),
            (ExternalFuncInst func) => invokeExternal(func),
        );
    }
}

private size_t getEndAddress(const(Instruction)[] insts, size_t pc)
{
    uint depth = 0;
    while (true)
    {
        pc++;
        const inst = insts[pc];

        const isTopLevelEnd = inst.match!(
            (binary.instruction.If _) {
                depth++;
                return false;
            },
            (End _) {
                if (depth == 0)
                {
                    return true;
                }
                depth--;
                return false;
            },
            (_) {
                return false;
            }
        );
        if (isTopLevelEnd)
        {
            return pc;
        }
    }
}

private void stack_unwind(ref Value[] stack, size_t sp, size_t arity)
{
    import std.range : back, popBack;
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
    const p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const tests = [
        [2, 3, 5],
        [10, 5, 15],
        [1, 1, 2]
    ];
    foreach (test; tests)
    {
        Value[] args = [Value(I32(test[0])), Value(I32(test[1]))];
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
    const p = executeShell("wasm-tools parse source/fixtures/func_add.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    assertThrown(runtime.call("foooo", []));
}

@("func call")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/func_call.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const tests = [
        [2, 4],
        [10, 20],
        [1, 2]
    ];

    foreach(test; tests)
    {
        Value[] args = [Value(I32(test[0]))];
        const result = runtime.call("call_doubler", args);
        result.get().match!(
            (I32 actual) => assert(actual.i == test[1]),
            _ => assert(false)
        );
    }
}

@("call imported func")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.addImport("env", "add", delegate Nullable!Value(_, args) {
        const arg = args[0];
        return arg.match!(
            (I32 value) => nullable(Value((value + value))),
            _ => assert(false),
        );
    });
    const tests = [
        [2, 4],
        [10, 20],
        [1, 2]
    ];

    foreach(test; tests)
    {
        Value[] args = [Value(I32(test[0]))];
        const result = runtime.call("call_add", args);
        result.get().match!(
            (I32 actual) => assert(actual.i == test[1]),
            _ => assert(false)
        );
    }
}

@("not found imported func")
unittest
{
    import std.exception;
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.addImport("env", "fooooo", delegate Nullable!Value(_, _args) {
        return typeof(return).init;
    });
    assertThrown(runtime.call("call_add", [Value(I32(1))]));
}

@("i32 const")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/i32_const.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const result = runtime.call("i32_const", [Value(I32(42))]);
    result.get().match!(
        (I32 actual) => assert(actual.i == 42),
        _ => assert(false)
    );
}

@("local set")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/local_set.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const result = runtime.call("local_set", []);
    result.get().match!(
        (I32 actual) => assert(actual.i == 42),
        _ => assert(false)
    );
}

@("i32 store")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/i32_store.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.call("i32_store", []);
    auto memory = runtime.store.memories[0].data;
    assert(memory[0] == 42);
}

@("i32 sub")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/func_sub.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const result = runtime.call("sub", [Value(I32(10)), Value(I32(5))]);
    assert(result == Value(I32(5)));
}

@("i32 lts")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/func_lts.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const result = runtime.call("lts", [Value(I32(10)), Value(I32(5))]);
    assert(result == Value(I32(0)));
}

@("fib")
unittest
{
    import std.process;
    const p = executeShell("wasm-tools parse source/fixtures/fib.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const tests = [
        [1, 1],
        [2, 2],
        [3, 3],
        [4, 5],
        [5, 8],
        [6, 13],
        [7, 21],
        [8, 34],
        [9, 55],
        [10, 89]
    ];
    foreach (test; tests)
    {
        const result = runtime.call("fib", [Value(I32(test[0]))]);
        assert(result == Value(I32(test[1])));
    }
}
