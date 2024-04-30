module binary.section;

import binary.instruction;
import binary.types;

///
enum SectionCode : ubyte
{
    Custom = 0x00,
    Type = 0x01,
    Import = 0x02,
    Function = 0x03,
    Memory = 0x05,
    Export = 0x07,
    Code = 0x0a,
    Data = 0x0b,
}

///
struct Function
{
    ///
    FunctionLocal[] locals;
    ///
    Instruction[] code;
}
