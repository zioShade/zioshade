#version 450

// Test: float precision edge cases
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float very_small = 1e-6;
    float very_large = 1e6;
    float neg = -1.0;
    float zero = 0.0;

    float a = very_small * uv.x;
    float b = very_large * uv.y;
    float c = abs(neg) * uv.x;
    float d = sign(uv.x - 0.5) * 0.5 + 0.5;

    gl_FragColor = vec4(clamp(a * 1e6, 0.0, 1.0), clamp(b / 1e6, 0.0, 1.0), c, d);
}
