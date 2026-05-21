#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    uint x = uint(uv.x * 255.0 + 128.0);
    uint y = uint(uv.y * 255.0 + 128.0);
    uint a = x ^ y;
    uint b = x & 0xFF00u;
    uint c = x | y;
    vec3 col = vec3(float(a & 0xFFu) / 255.0, float(b >> 8u) / 255.0, float(c & 0xFFu) / 255.0);
    fragColor = vec4(col, 1.0);
}
