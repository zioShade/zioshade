#version 310 es
precision highp float;
out vec4 fragColor;

// Test: mat2 * mat2 * vec2 chain
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    mat2 a = mat2(cos(uv.x), -sin(uv.x), sin(uv.x), cos(uv.x));
    mat2 b = mat2(0.5, 0.0, 0.0, 0.5);
    vec2 result = a * b * uv;
    float val = length(result);
    vec3 col = vec3(val * 0.5, val * 0.3, val * 0.8);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
