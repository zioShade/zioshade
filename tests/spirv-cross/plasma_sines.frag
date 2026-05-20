#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Plasma effect with sine combinations
    float v1 = sin(uv.x * 5.0);
    float v2 = sin(uv.y * 5.0);
    float v3 = sin((uv.x + uv.y) * 5.0);
    float v4 = sin(length(uv - vec2(15.0)) * 5.0);
    float v = (v1 + v2 + v3 + v4) * 0.25;
    // Map to colors
    float r = sin(v * 3.14159) * 0.5 + 0.5;
    float g = sin(v * 3.14159 + 2.094) * 0.5 + 0.5;
    float b = sin(v * 3.14159 + 4.189) * 0.5 + 0.5;
    fragColor = vec4(r, g, b, 1.0);
}
