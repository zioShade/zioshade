import subprocess, struct

def make_asm(name, nargs):
    args = " ".join(["%f1","%f2","%f3"][:nargs])
    return f"""OpCapability Shader
%glsl = OpExtInstImport "GLSL.std.450"
OpMemoryModel Logical GLSL450
OpEntryPoint GLCompute %main "main"
%void = OpTypeVoid
%vfun = OpTypeFunction %void
%float = OpTypeFloat 32
%f1 = OpConstant %float 1.0
%f2 = OpConstant %float 2.0
%f3 = OpConstant %float 3.0
%main = OpFunction %void None %vfun
%lbl = OpLabel
%r = OpExtInst %float %glsl {name} {args}
OpReturn
OpFunctionEnd"""

builtins = [
    ("Round", 1), ("RoundEven", 1), ("Trunc", 1), ("FAbs", 1), ("SAbs", 1),
    ("FSign", 1), ("SSign", 1), ("Floor", 1), ("Ceil", 1), ("Fract", 1),
    ("Radians", 1), ("Degrees", 1), ("Sin", 1), ("Cos", 1), ("Tan", 1),
    ("Asin", 1), ("Acos", 1), ("Atan", 1), ("Sinh", 1), ("Cosh", 1),
    ("Tanh", 1), ("Asinh", 1), ("Acosh", 1), ("Atanh", 1), ("Atan2", 2),
    ("Pow", 2), ("Exp", 1), ("Log", 1), ("Exp2", 1), ("Log2", 1),
    ("Sqrt", 1), ("InverseSqrt", 1), ("Determinant", 1), ("MatrixInverse", 1),
    ("Modf", 2), ("ModfStruct", 1),
    ("FMin", 2), ("UMin", 2), ("SMin", 2), ("FMax", 2), ("UMax", 2), ("SMax", 2),
    ("FClamp", 3), ("UClamp", 3), ("SClamp", 3),
    ("FMix", 3), ("Step", 2), ("SmoothStep", 3),
    ("Fma", 3), ("Frexp", 2), ("FrexpStruct", 1), ("Ldexp", 2),
    ("Length", 1), ("Distance", 2), ("Cross", 2), ("Normalize", 1),
    ("FaceForward", 3), ("Reflect", 2), ("Refract", 3),
]

for name, nargs in builtins:
    asm = make_asm(name, nargs)
    asm_file = f"t_{name}.asm"
    spv_file = f"t_{name}.spv"
    with open(asm_file,"w") as f:
        f.write(asm)
    r = subprocess.run(["spirv-as", asm_file, "-o", spv_file], capture_output=True)
    if r.returncode != 0:
        print(f"{name} = FAIL")
        continue
    with open(spv_file, "rb") as f:
        data = f.read()
    n = len(data) // 4
    words = struct.unpack("<" + "I"*n, data)
    i = 5
    found = False
    while i < n:
        w = words[i]
        wc = w >> 16
        op = w & 0xFFFF
        if wc == 0: break
        if op == 12:
            print(f"{name} = {words[i+4]}")
            found = True
            break
        i += wc
    if not found:
        print(f"{name} = NOT_FOUND")
