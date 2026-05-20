#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Multiple return paths from function
    float threshold = 0.5;
    float val = sin(uv.x * 3.0) * cos(uv.y * 4.0) * 0.5 + 0.5;
    vec3 col;
    if (val > 0.7) {
        col = vec3(1.0, 0.5, 0.0);
    } else if (val > 0.5) {
        col = vec3(0.0, 0.7, 1.0);
    } else if (val > 0.3) {
        col = vec3(0.0, 1.0, 0.5);
    } else {
        col = vec3(0.3, 0.0, 0.5);
    }
    fragColor = vec4(col, 1.0);
}
