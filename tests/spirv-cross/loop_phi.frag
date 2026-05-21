#version 310 es
precision highp float;
out vec4 fragColor;

// Test: loop variable with phi dependency
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float prev = 0.0;
    float curr = 1.0;
    for (int i = 0; i < 8; i++) {
        float next = prev + curr;
        prev = curr;
        curr = next;
    }
    float normalized = curr / 34.0;
    vec3 col = vec3(normalized * (0.5 + 0.5 * sin(dot(uv, uv) * normalized * 10.0)));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
