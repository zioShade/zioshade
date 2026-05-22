#version 310 es
precision highp float;
out vec4 fragColor;

// Compound assignment on matrix columns
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    mat2 m = mat2(1.0, 0.0, 0.0, 1.0);
    m[0] += vec2(0.1, 0.2);
    m[1] *= vec2(0.5, 0.8);

    vec2 result = m * uv;
    float val = length(result);
    vec3 col = vec3(fract(val));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
