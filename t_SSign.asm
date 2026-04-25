OpCapability Shader
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
%r = OpExtInst %float %glsl SSign %f1
OpReturn
OpFunctionEnd