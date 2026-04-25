OpCapability Shader
%1 = OpExtInstImport "GLSL.std.450"
OpMemoryModel Logical GLSL450
OpEntryPoint GLCompute %main "main"
%void = OpTypeVoid
%vf = OpTypeFunction %void
%float = OpTypeFloat 32
%f1 = OpConstant %float 1.0
%f2 = OpConstant %float 2.0
%main = OpFunction %void None %vf
%lbl = OpLabel
%result = OpExtInst %float %1 Reflect %f1 %f2
OpReturn
OpFunctionEnd