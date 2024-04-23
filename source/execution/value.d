module execution.value;

import std.sumtype;

struct I32
{
    int i;
    I32 opBinary(string op : "+")(I32 rhs)
    {
        return I32(i + rhs.i);
    }
}

struct I64
{
    long i;
    I64 opBinary(string op : "+")(I64 rhs)
    {
        return I64(i + rhs.i);
    }
}

alias Value = SumType!(
    I32,
    I64
);
