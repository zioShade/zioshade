import subprocess, struct

def make_asm(name, nargs):
    lines = [
        "OpCapability Shader",
        "%glsl = OpExtInstImport \"GLSL.std.450\"",
        "OpMemoryModel Logical GLSL450",
        "OpEntryPoint GLCompute %main \"main\"",
        "%void = OpTypeVoid",
        "%vfun = OpTypeFunction %void",
        "%float = OpTypeFloat 32",
        "%f1 = OpConstant %float 1.0",
        "%f2 = OpConstant %float 2.0",
        "%main = OpFunction %void None %vfun",
        "%lbl = OpLabel",
        "%r = OpExtInst %float %glsl " + name + " " + " ".join(["%f1","%f2"][:nargs]),
        "OpReturn",
        "OpFunctionEnd",
    ]
    return "\n".join(lines)

for name, nargs in [("Length",1),("Distance",2),("Cross",2),("Normalize",1),("Reflect",2)]:
    with open("t.asm","w") as f:
        f.write(make_asm(name, nargs))
    r = subprocess.run(["spirv-as","t.asm","-o","t.spv"], capture_output=True)
    if r.returncode != 0:
        print(f"{name}: FAIL {r.stderr.decode()[:100]}")
    else:
        with open("t.spv","rb") as f: data = f.read()
        words = struct.unpack("<" + "I"*(len(data)//4), data)
        for i in range(5, len(words)):
            w = words[i]
            if (w>>16)==0: break
            if (w&0xFFFF)==12:
                print(f"{name} = {words[i+4]}")
                break
