#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = 1.0;
    float b;
    vec3 col;
    if (r < 0.5) {
        a = 0.8;
        b = 0.3;
        col = vec3(0.7, 0.2, 0.1);
    } else {
        a = 0.2;
        b = 0.9;
        col = vec3(0.1, 0.5, 0.8);
    }
    col *= a + b;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
