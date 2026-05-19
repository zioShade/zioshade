#version 450

// Test: clamp patterns with min/max
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float a = clamp(uv.x * 3.0 - 1.0, 0.0, 1.0);
    float b = min(uv.y * 2.0, 1.0);
    float c = max(uv.x + uv.y - 1.0, 0.0);
    float d = clamp(uv.x - uv.y, -1.0, 1.0) * 0.5 + 0.5;

    gl_FragColor = vec4(a, b, c, d);
}
