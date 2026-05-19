#version 450

// Test: vec4 shuffle with all 4-component permutations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 a = vec4(0.1, 0.2, 0.3, 0.4);

    vec4 b = a.xyzw;
    vec4 c = a.wzyx;
    vec4 d = a.xxyy;
    vec4 e = a.zzww;

    float x = b.x + c.y + d.z + e.w;
    gl_FragColor = vec4(x + uv.x, x + uv.y, x, 1.0);
}
