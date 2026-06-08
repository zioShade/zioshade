#version 450
// #200: textureSize on int/uint 2D-MS-array samplers must return ivec3
// ({width,height,layers}) — matching glslang — and on int/uint texel-buffer
// samplers must return int (the buffer half was resolved in #194). All results
// flow to the output so the image queries escape DCE.
layout(location = 0) out vec4 o;

layout(binding = 0) uniform isampler2DMSArray ims;
layout(binding = 1) uniform usampler2DMSArray ums;
layout(binding = 2) uniform sampler2DMSArray  fms;
layout(binding = 3) uniform isamplerBuffer     ib;
layout(binding = 4) uniform usamplerBuffer     ub;

void main() {
    ivec3 a = textureSize(ims);
    ivec3 b = textureSize(ums);
    ivec3 c = textureSize(fms);
    int   d = textureSize(ib);
    int   e = textureSize(ub);
    o = vec4(a + b + c, float(d + e));
}
