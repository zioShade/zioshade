#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a; float b;
    if (r < 0.3) {
        a = 0.8; b = 0.2;
    } else if (r < 0.6) {
        a = 0.4; b = 0.6;
    } else {
        a = 0.1; b = 0.9;
    }
    vec3 col = vec3(a, b, a * b);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
