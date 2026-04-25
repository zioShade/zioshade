               OpCapability Shader
          %1 = OpExtInstImport "GLSL.std.450"
               OpMemoryModel Logical GLSL450
               OpEntryPoint GLCompute %main "main"
       %void = OpTypeVoid
   %voidfunc = OpTypeFunction %void
      %float = OpTypeFloat 32
    %float_1 = OpConstant %float 1.0
    %float_2 = OpConstant %float 2.0
       %main = OpFunction %void None %voidfunc
      %label = OpLabel
     %result = OpExtInst %float %1 65 %float_1 %float_2
               OpReturn
               OpFunctionEnd
