#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Pack/unpack
    uint packed = packSnorm2x16(uv);
    vec2 unpacked = unpackSnorm2x16(packed);
    uint packed2 = packUnorm2x16(uv);
    vec2 unpacked2 = unpackUnorm2x16(packed2);
    float h = packHalf2x16(uv);
    vec2 unpacked3 = unpackHalf2x16(h);
    fragColor = vec4(unpacked, unpacked2);
}
