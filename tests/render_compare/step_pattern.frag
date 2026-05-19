#version 430
layout(location = 0) out vec4 FragColor;

// Test: step function pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float s1 = step(0.5, uv.x);
    float s2 = step(0.3, uv.y);
    float s3 = step(0.7, uv.x);
    vec2 sv = step(vec2(0.4, 0.6), uv);
    FragColor = vec4(s1 * s2, sv.x, sv.y * s3, 1.0);
}
