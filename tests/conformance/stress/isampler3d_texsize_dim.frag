// Tests: textureSize on int/uint 3D samplers — issue #193.
// A 3D texture's size is ivec3 (glslang -> OpImageQuerySizeLod %v3int).
// Pre-fix glslpp listed .isampler3d/.usampler3d under the ivec2 result-dim arm
// of the textureSize switch, producing OpImageQuerySizeLod %v2int — spirv-val
// "Result Type has 2 components, but 3 expected" (or a semantic TypeMismatch
// when assigned to an ivec3). Regression-guard: float sampler3D was already
// ivec3, and isampler2D must stay ivec2.
// All results are written to fragColor so the queries escape DCE.
#version 450
layout(binding = 0) uniform isampler3D si;
layout(binding = 1) uniform usampler3D su;
layout(binding = 2) uniform sampler3D  sf;
layout(binding = 3) uniform isampler2D s2;
layout(location = 0) out vec4 fragColor;

void main() {
    ivec3 a = textureSize(si, 0);  // isampler3D -> ivec3
    ivec3 b = textureSize(su, 0);  // usampler3D -> ivec3
    ivec3 c = textureSize(sf, 0);  // sampler3D  -> ivec3 (regression guard)
    ivec2 d = textureSize(s2, 0);  // isampler2D -> ivec2 (regression guard)
    fragColor = vec4(
        float(a.x + a.y + a.z),
        float(b.x + b.y + b.z),
        float(c.x + c.y + c.z),
        float(d.x + d.y)
    );
}
