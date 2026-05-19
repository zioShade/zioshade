#version 450

// Test: ternary cascade for discretization
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;

    int level = (x > 0.75) ? 3 : (x > 0.5) ? 2 : (x > 0.25) ? 1 : 0;
    float f = float(level) / 3.0;

    gl_FragColor = vec4(f, uv.y, 1.0 - f, 1.0);
}
