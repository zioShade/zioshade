const std = @import("std");

pub const Op = enum(u16) {
    Nop = 0,
    Undef = 1,
    Source = 3,
    Name = 5,
    MemberName = 6,
    ExtInstImport = 11,
    ExtInst = 12,
    MemoryModel = 14,
    EntryPoint = 15,
    ExecutionMode = 16,
    Capability = 17,
    TypeVoid = 19,
    TypeBool = 20,
    TypeInt = 21,
    TypeFloat = 22,
    TypeVector = 23,
    TypeMatrix = 24,
    TypeImage = 25,
    TypeSampler = 26,
    TypeSampledImage = 27,
    TypeArray = 28,
    TypeRuntimeArray = 29,
    TypeStruct = 30,
    TypePointer = 32,
    TypeFunction = 33,
    ConstantTrue = 41,
    ConstantFalse = 42,
    Constant = 43,
    ConstantComposite = 44,
    Function = 54,
    FunctionParameter = 55,
    FunctionEnd = 56,
    FunctionCall = 57,
    Variable = 59,
    Load = 61,
    Store = 62,
    AccessChain = 65,
    Decorate = 71,
    MemberDecorate = 72,
    VectorShuffle = 79,
    CompositeConstruct = 80,
    CompositeExtract = 81,
    SNegate = 126,
    FNegate = 127,
    IAdd = 128,
    ISub = 129,
    IMul = 130,
    SDiv = 131,
    UDiv = 132,
    SRem = 133,
    URem = 134,
    FAdd = 137,
    FSub = 138,
    FMul = 139,
    FDiv = 140,
    FRem = 141,
    ConvertFToU = 109,
    ConvertFToS = 110,
    ConvertUToF = 111,
    ConvertSToF = 112,
    Bitcast = 124,
    VectorTimesScalar = 142,
    MatrixTimesScalar = 143,
    VectorTimesMatrix = 144,
    MatrixTimesVector = 145,
    MatrixTimesMatrix = 146,
    OuterProduct = 147,
    Dot = 148,
    Transpose = 149,
    LogicalNot = 154,
    LogicalAnd = 155,
    LogicalOr = 156,
    IEqual = 161,
    INotEqual = 162,
    SLessThan = 163,
    ULessThan = 164,
    SGreaterThan = 165,
    UGreaterThan = 166,
    SLessThanEqual = 167,
    ULessThanEqual = 168,
    SGreaterThanEqual = 169,
    Select = 169,
    FOrdEqual = 178,
    FOrdNotEqual = 180,
    FOrdLessThan = 182,
    FOrdGreaterThan = 184,
    FOrdLessThanEqual = 186,
    FOrdGreaterThanEqual = 188,
    ImageSampleImplicitLod = 87,
    ImageFetch = 95,
    Label = 248,
    Return = 57,
    Branch = 57,
    _,
};

pub const Capability = enum(u32) {
    shader = 1,
    sampled_image_array_dynamic_indexing = 2,
    image_cube_array = 3,
    sample_rate_shading = 5,
    _,
};

pub const BuiltIn = enum(u32) {
    position = 0,
    frag_coord = 15,
    frag_color = 17,
    _,
};

pub const Decoration = enum(u32) {
    block = 2,
    row_major = 3,
    array_stride = 6,
    matrix_stride = 7,
    location = 30,
    binding = 33,
    descriptor_set = 34,
    offset = 35,
    _,
};

pub const GLSLstd450 = enum(u32) {
    Round = 1,
    RoundEven = 2,
    Trunc = 3,
    FAbs = 4,
    FSign = 6,
    Floor = 8,
    Ceil = 10,
    Fract = 12,
    Radians = 14,
    Degrees = 16,
    Sin = 18,
    Cos = 20,
    Tan = 22,
    Asin = 24,
    Acos = 26,
    Atan = 28,
    Atan2 = 30,
    Sinh = 32,
    Cosh = 34,
    Tanh = 36,
    Asinh = 38,
    Acosh = 40,
    Atanh = 42,
    Pow = 48,
    Exp = 50,
    Log = 52,
    Exp2 = 54,
    Log2 = 56,
    Sqrt = 58,
    InverseSqrt = 60,
    Abs = 62,
    Sign = 64,
    FMin = 72,
    FMax = 74,
    FClamp = 76,
    FMix = 78,
    Step = 80,
    SmoothStep = 82,
    Length = 84,
    Distance = 86,
    Cross = 88,
    Normalize = 90,
    FaceForward = 92,
    Reflect = 94,
    Refract = 96,
    Determinant = 100,
    MatrixInverse = 102,
    _,
};

pub const MAGIC: u32 = 0x07230203;

pub fn encodeInstructionHeader(word_count: u16, opcode: u16) u32 {
    return (@as(u32, word_count) << 16) | opcode;
}

pub fn encodeVersion(major: u8, minor: u8, patch: u8) u32 {
    return (@as(u32, major) << 16) | (@as(u32, minor) << 8) | patch;
}

test "instruction header encoding" {
    const header = encodeInstructionHeader(3, 54);
    try std.testing.expectEqual(@as(u32, 0x00030036), header);
}

test "magic number" {
    try std.testing.expectEqual(@as(u32, 0x07230203), MAGIC);
}

test "version encoding" {
    try std.testing.expectEqual(@as(u32, 0x00010500), encodeVersion(1, 5, 0));
}