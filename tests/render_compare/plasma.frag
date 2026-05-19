#version 430
layout(location = 0) out vec4 FragColor;

// Test: plasma effect
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float v1 = sin(uv.x * 10.0);
    float v2 = sin(uv.y * 10.0);
    float v3 = sin((uv.x + uv.y) * 10.0);
    float v4 = sin(length(uv - 0.5) * 14.0);
    float v = (v1 + v2 + v3 + v4) * 0.25;
    vec3 col = vec3(sin(v * 3.14) * 0.5 + 0.5, sin(v * 3.14 + 2.09) * 0.5 + 0.5, sin(v * 3.14 + 4.19) * 0.5 + 0.5);
    FragColor = vec4(col, 1.0);
}
