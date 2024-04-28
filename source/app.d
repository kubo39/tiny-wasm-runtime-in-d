import execution.wasi : WasiSnapshotPreview1;
import execution.runtime : Runtime;

import std.stdio;

void main()
{
    auto wasi = WasiSnapshotPreview1(
        fileTable: [stdin, stdout, stderr]
    );
    const(ubyte)[] wasm = cast(const(ubyte)[]) import("hello_world.wasm");
    auto runtime = Runtime.instantiate(wasm, wasi);
    runtime.call("_start", []);
}
