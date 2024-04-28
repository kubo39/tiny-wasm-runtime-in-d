module execution.wasi;

import execution.value;
import execution.store;

import std.array : array;
import std.bitmanip : peek, write;
import std.stdio;
import std.sumtype;
import std.system : Endian;
import std.typecons : Nullable, nullable;

struct WasiSnapshotPreview1
{
    File[] fileTable;
    
    this(File[] fileTable)
    {
        this.fileTable = fileTable;
    }

    Nullable!Value invoke(ref Store store, string func, Value[] args)
    {
        switch (func)
        {
        case "fd_write":
            return fdWrite(store, args);
        default:
            assert(false, "not implemented yet");
        }
        assert(false);
    }

    Nullable!Value fdWrite(ref Store store, Value[] args)
    {
        import std.algorithm : map;

        int[] _args = args.map!((Value arg) {
            return arg.match!(
                (I32 i32) => i32.i,
                _ => assert(false)
            )();
        }).array;

        int fd = _args[0];
        size_t iovs = _args[1];
        int iovsLen = _args[2];
        const size_t rp = _args[3];

        auto file = fileTable[fd];
        auto memory = store.memories[0];

        int nwritten = 0;

        foreach (_; 0..iovsLen)
        {
            const start = memory.data.peek!(int, Endian.littleEndian)(&iovs);
            const len = memory.data.peek!(int, Endian.littleEndian)(&iovs);
            const end = start + len;
            file.rawWrite(memory.data[start..end]);
            nwritten += len;
        }
        memory.data.write!(int, Endian.littleEndian)(nwritten, rp);

        return nullable(cast(Value) I32(0));
    }
}


