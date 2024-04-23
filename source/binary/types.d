module binary.types;

struct FuncType
{
    ValueType[] params;
    ValueType[] results;
}

enum ValueType
{
    I32 = 0x7F,
    I64 = 0x7E,
}

struct FunctionLocal
{
    uint typeCount;
    ValueType valueType;
}
