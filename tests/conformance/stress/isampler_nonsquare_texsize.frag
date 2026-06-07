// Tests: int/uint non-2D sampler image-query (textureSize) — issue #188.
// textureSize on int/uint cube / cube-array / 2D-array samplers must lower to an
// OpImage extraction whose result type is the correct, distinct inner
// OpTypeImage. Pre-fix these referenced an undefined id (spirv-val "ID has not
// been defined") or collided onto the 2D-int image when a 2D int sampler also
// existed. All results are written to fragColor so the extractions escape DCE.
#version 450
layout(binding = 0) uniform isampler2D        s2;
layout(binding = 1) uniform isamplerCube      sc;
layout(binding = 2) uniform isamplerCubeArray sca;
layout(binding = 3) uniform usamplerCubeArray uca;
layout(binding = 4) uniform isampler2DArray   s2a;
layout(location = 0) out vec4 fragColor;

void main() {
    ivec2 a = textureSize(s2, 0);
    ivec2 b = textureSize(sc, 0);
    ivec3 c = textureSize(sca, 0);
    ivec3 d = textureSize(uca, 0);
    ivec3 e = textureSize(s2a, 0);
    fragColor = vec4(
        float(a.x + a.y + b.x + b.y),
        float(c.x + c.y + c.z),
        float(d.x + d.y + d.z + e.x + e.y + e.z),
        1.0
    );
}
