#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Integer arithmetic with uint conversion
    uint a = uint(uv.x * 100.0);
    uint b = uint(uv.y * 100.0);
    uint c = (a & 0xFFu) ^ (b | 0x0Fu);
    uint d = c >> 2u;
    float val = float(d) / 64.0;

    vec3 col = vec3(val, fract(val * 2.0), fract(val * 3.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
