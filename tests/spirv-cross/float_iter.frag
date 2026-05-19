#version 450

// Test: loop with float-based iteration
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = 0.0;
    float step_size = uv.x * 0.1;

    for (int i = 0; i < 10; i++) {
        x += step_size;
        x = mod(x, 1.0);
    }

    gl_FragColor = vec4(x, uv.y, 1.0 - x, 1.0);
}
