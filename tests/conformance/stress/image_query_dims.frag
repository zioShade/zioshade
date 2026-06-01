#version 450
// Tests: imageSize/textureSize result dimensions across image/sampler ranks.
// imageSize previously always returned ivec2 (silent-wrong for 1D/buffer/array/3D);
// textureSize(sampler2DMSArray) previously defaulted to ivec2 instead of ivec3.
layout(r32f, binding = 0) uniform image1D i1;
layout(r32f, binding = 1) uniform image2D i2;
layout(r32f, binding = 2) uniform image2DArray i2a;
layout(r32f, binding = 3) uniform image3D i3;
layout(r32f, binding = 4) uniform imageBuffer ib;
layout(r32f, binding = 5) uniform imageCubeArray ica;
layout(binding = 6) uniform sampler2DMSArray smsa;
layout(location = 0) out vec4 o;

void main() {
    int a = imageSize(i1);        // 1D     -> int
    ivec2 b = imageSize(i2);      // 2D     -> ivec2
    ivec3 c = imageSize(i2a);     // 2DArr  -> ivec3
    ivec3 d = imageSize(i3);      // 3D     -> ivec3
    int e = imageSize(ib);        // buffer -> int
    ivec3 f = imageSize(ica);     // cubeArr-> ivec3
    ivec3 g = textureSize(smsa);  // 2DMSArr-> ivec3
    o = vec4(float(a + e), float(b.x + c.x + d.x), float(f.x + g.x), 1.0);
}
