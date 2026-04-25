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
    ("PackSnorm4x8", 1), ("PackSnorm2x16", 1), ("PackUnorm4x8", 1), ("PackUnorm2x16", 1),
    ("PackHalf2x16", 1), ("PackDouble2x32", 1),
    ("UnpackSnorm2x16", 1), ("UnpackUnorm2x16", 1), ("UnpackHalf2x16", 1), ("UnpackDouble2x32", 1),
    ("UnpackSnorm4x8", 1), ("UnpackUnorm4x8", 1),
    ("IMix", 3),
]

for name, nargs in builtins:
    asm = make_asm(name, nargs)
    asm_file = f"t2_{name}.asm"
    spv_file = f"t2_{name}.spv"
    with open(asm_file, "w") as f:
        f.write(asm)
    r = subprocess.run(["spirv-as", asm_file, "-o", spv_file], capture_output=True)
    if r.returncode != 0:
        print(f"{name} = FAIL ({r.stderr.decode().strip()[:60]})")
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
