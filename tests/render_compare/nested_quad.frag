#version 430
layout(location = 0) out vec4 FragColor;

// Test: nested if-else with vec3 output
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col;
    if (uv.x < 0.5) {
        if (uv.y < 0.5) {
            col = vec3(1.0, 0.0, 0.0);
        } else {
            col = vec3(0.0, 1.0, 0.0);
        }
    } else {
        if (uv.y < 0.5) {
            col = vec3(0.0, 0.0, 1.0);
        } else {
            col = vec3(1.0, 1.0, 0.0);
        }
    }
    FragColor = vec4(col, 1.0);
}
