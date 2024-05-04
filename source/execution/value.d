module execution.value;

import std.sumtype;

///
struct I32
{
    ///
    int i;

    ///
    I32 opBinary(string op : "+")(I32 rhs)
    {
        return I32(i + rhs.i);
    }

    ///
    I32 opBinary(string op : "-")(I32 rhs)
    {
        return I32(i - rhs.i);
    }

    ///
    int opCmp(I32 rhs) const
    {
        return (i > rhs.i) - (i < rhs.i);
    }
}

///
struct I64
{
    ///
    long i;

    ///    
    I64 opBinary(string op : "+")(I64 rhs)
    {
        return I64(i + rhs.i);
    }

    ///
    I64 opBinary(string op : "-")(I64 rhs)
    {
        return I64(i - rhs.i);
    }

    ///
    int opCmp(I64 rhs) const
    {
        return (i > rhs.i) - (i < rhs.i);
    }
}

alias Value = SumType!(
    I32,
    I64
);

///
struct If {}

alias LabelKind = SumType!(
    If
);

///
struct Label
{
    ///
    LabelKind kind;
    ///
    size_t pc;
    ///
    size_t sp;
    ///
    size_t arity;
}
