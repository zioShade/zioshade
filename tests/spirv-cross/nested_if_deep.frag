#version 450

// Test: nested if-else with multiple levels
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;
    vec3 col;

    if (x < 0.33) {
        if (y < 0.5) {
            col = vec3(0.8, 0.2, 0.1);
        } else {
            col = vec3(0.1, 0.8, 0.2);
        }
    } else if (x < 0.66) {
        if (y < 0.33) {
            col = vec3(0.2, 0.1, 0.8);
        } else if (y < 0.66) {
            col = vec3(0.8, 0.8, 0.1);
        } else {
            col = vec3(0.1, 0.8, 0.8);
        }
    } else {
        if (y < 0.5) {
            col = vec3(0.5, 0.1, 0.5);
        } else {
            col = vec3(0.9, 0.5, 0.1);
        }
    }

    gl_FragColor = vec4(col, 1.0);
}
