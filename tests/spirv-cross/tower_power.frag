#version 450

// Test: recursive-like pattern using loop (tower of powers)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 2.0;

    float result = x;
    for (int i = 0; i < 4; i++) {
        result = pow(max(result, 0.001), 0.5);
    }

    gl_FragColor = vec4(result, uv.y, 1.0 - result, 1.0);
}
