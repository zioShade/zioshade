#version 450

// Test: ivec and uvec types
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    ivec2 iv = ivec2(uv * 4.0);
    uvec2 uv2 = uvec2(uv * 255.0);

    int a = iv.x + iv.y;
    uint b = uv2.x + uv2.y;
    int c = iv.x * 2 - iv.y;

    float r = float(a) / 8.0;
    float g = float(b) / 510.0;
    float bl = float(c & 0x7) / 8.0;

    gl_FragColor = vec4(r, g, bl, 1.0);
}
