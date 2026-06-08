// Tests: isamplerBuffer / usamplerBuffer texel-buffer fetch + size — issue #194.
// Pre-fix glslpp had no parser keyword for isamplerBuffer/usamplerBuffer, so the
// declarations never reached the (already-present) codegen arms; had they, the
// type fell through to an empty OpTypeStruct → spirv-val "Expected Image to be of
// type OpTypeImage". Post-fix each emits OpTypeImage <int|uint> Buffer 0 0 0 1
// Unknown, so texelFetch -> OpImageFetch (%v4int / %v4uint) and textureSize ->
// OpImageQuerySize (%int) validate cleanly. Float samplerBuffer is the
// regression guard (was already correct).
// All results are written to fragColor so the queries escape DCE.
#version 450
layout(binding = 0) uniform isamplerBuffer si;
layout(binding = 1) uniform usamplerBuffer su;
layout(binding = 2) uniform samplerBuffer  sf;
layout(location = 0) out vec4 fragColor;

void main() {
    ivec4 a = texelFetch(si, 3);   // isamplerBuffer -> ivec4
    int   na = textureSize(si);    // -> int
    uvec4 b = texelFetch(su, 5);   // usamplerBuffer -> uvec4
    int   nb = textureSize(su);    // -> int
    vec4  c = texelFetch(sf, 7);   // samplerBuffer  -> vec4 (regression guard)
    int   nc = textureSize(sf);    // -> int
    fragColor = vec4(a) + vec4(b) + c
        + vec4(float(na + nb + nc));
}
