#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Nested ternary with function calls
    float v = uv.x > 0.5 ? sin(uv.x * 6.28) : cos(uv.y * 6.28);
    float w = uv.y > 0.5 ? abs(v) : -abs(v);
    fragColor = vec4(v * 0.5 + 0.5, w * 0.5 + 0.5, 0.5, 1.0);
}
