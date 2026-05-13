#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec3 col = vec3(0.0);
    // Nested if-else
    if (uv.x < 0.5) {
        if (uv.y < 0.5) {
            col = vec3(0.2, 0.4, 0.8);
        } else {
            col = vec3(0.8, 0.4, 0.2);
        }
    } else {
        if (uv.y < 0.333) {
            col = vec3(0.1, 0.8, 0.3);
        } else if (uv.y < 0.666) {
            col = vec3(0.9, 0.1, 0.5);
        } else {
            col = vec3(0.3, 0.3, 0.9);
        }
    }
    FragColor = vec4(col, 1.0);
}
