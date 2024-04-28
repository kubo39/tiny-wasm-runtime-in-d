module execution.runtime;

import binary.instruction;
import binary.mod;
import binary.types;

import execution.store;
import execution.value;
import execution.wasi : WasiSnapshotPreview1;

import std.bitmanip : write;
import std.exception : enforce;
import std.range;
import std.stdio;
import std.sumtype;
import std.system : Endian;
import std.typecons;

alias ImportFunc = Nullable!Value delegate(ref Store, Value[]);
alias Import = ImportFunc[string][string];

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
    Import import_;
    Nullable!WasiSnapshotPreview1 wasi;

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
                (LocalSet localSet) {
                    Value value = this.stack.back;
                    this.stack.popBack();
                    frame.locals[localSet.idx] = value;
                },
                (End _) {
                    auto frame = this.callStack.back;
                    this.callStack.popBack();
                    stack_unwind(this.stack, frame.sp, frame.arity);
                },
                (I32Store i32store) {
                    Value value_ = this.stack.back;
                    this.stack.popBack();
                    Value valueAddr = this.stack.back;
                    this.stack.popBack();
                    const addr = cast(size_t) valueAddr.match!(
                        (I32 value) => value.i,
                        _ => assert(false)
                    );
                    const offset = cast(size_t) i32store.offset;
                    const at = addr + offset;
                    auto memory = this.store.memories[0];
                    int value = value_.match!(
                        (I32 i32) => i32.i,
                        _ => assert(false)
                    );
                    memory.data.write!(int, Endian.littleEndian)(value, at);
                },
                (I32Const i32const) {
                    this.stack ~= cast(Value) I32(i32const.value);
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
                        },
                    );
                }
            );
        }
    }

    void pushFrame(InternalFuncInst func)
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
        this.stack = this.stack[0..bottom];
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
    static Runtime instantiate(const(ubyte)[] wasm)
    {
        auto mod = decodeModule(wasm);
        auto store = Store(mod);
        return Runtime(store: store);
        }

    static Runtime instantiate(const(ubyte)[] wasm, ref WasiSnapshotPreview1 wasi)
    {
        auto mod = decodeModule(wasm);
        auto store = Store(mod);
        return Runtime(
            store: store,
            wasi: nullable(wasi)
        );
    }

    void addImport(string moduleName, string funcName, ImportFunc func)
    {
        this.import_[moduleName][funcName] = func;
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
            (InternalFuncInst func) => invokeInternal(func),
            (ExternalFuncInst func) => invokeExternal(func),
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

@("func call")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/func_call.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const tests = [
        [2, 4],
        [10, 20],
        [1, 2]
    ];

    foreach(test; tests)
    {
        Value[] args = [cast(Value) I32(test[0])];
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
    auto p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.addImport("env", "add", delegate Nullable!Value(_, args) {
        const arg = args[0];
        return arg.match!(
            (I32 value) => nullable(cast(Value) (value + value)),
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
        Value[] args = [cast(Value) I32(test[0])];
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
    auto p = executeShell("wasm-tools parse source/fixtures/import.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.addImport("env", "fooooo", delegate Nullable!Value(_, _args) {
        return typeof(return).init;
    });
    assertThrown(runtime.call("call_add", [cast(Value) I32(1)]));
}

@("i32 const")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/i32_const.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    const result = runtime.call("i32_const", [cast(Value) I32(42)]);
    result.get().match!(
        (I32 actual) => assert(actual.i == 42),
        _ => assert(false)
    );
}

@("local set")
unittest
{
    import std.process;
    auto p = executeShell("wasm-tools parse source/fixtures/local_set.wat");
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
    auto p = executeShell("wasm-tools parse source/fixtures/i32_store.wat");
    const (ubyte)[] wasm = cast(ubyte[]) p.output;
    auto runtime = Runtime.instantiate(wasm);
    runtime.call("i32_store", []);
    auto memory = runtime.store.memories[0].data;
    assert(memory[0] == 42);
}
