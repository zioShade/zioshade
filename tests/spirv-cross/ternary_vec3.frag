#version 450

// Test: nested ternary in vec3 construction
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    vec3 col = vec3(
        x > 0.5 ? 1.0 : 0.0,
        y > 0.5 ? (x > 0.5 ? 1.0 : 0.5) : 0.0,
        (x + y > 1.0) ? 1.0 : 0.0
    );

    gl_FragColor = vec4(col, 1.0);
}
