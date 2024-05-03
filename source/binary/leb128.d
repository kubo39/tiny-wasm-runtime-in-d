module binary.leb128;

private import std.bitmanip : read;

package T leb128(T)(ref const(ubyte)[] input)
    if (is(T == int) || is(T == uint))
{
    T val = 0;
    uint shift = 0;
    enum size = 8 << 3;
    ubyte b;

    while (true)
    {
        b = input.read!ubyte();
        val |= (b & 0x7F) << shift;
        shift += 7;
        if ((b & 0x80) == 0) break;
    }
    static if (is(T == int))
    {
        // sign bit must be extended.
        if (shift < size && (b & 0x40) != 0)
            val |= -(1 << shift);
    }
    return val;
}
