module binary.opcode;

enum OpCode
{
    End = 0x0B,
    LocalGet = 0x20,
    LocalSet = 0x21,
    I32Const = 0x41,
    I32Add = 0x6A,
    Call = 0x10,
}
