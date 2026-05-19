#version 430
layout(location = 0) out vec4 FragColor;

// Test: gradient with mat2 rotation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float angle = 0.7854; // 45 degrees
    mat2 rot = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    vec2 ruv = rot * uv;
    float d = length(ruv);
    vec3 col = vec3(ruv * 0.5 + 0.5, d * 0.5);
    FragColor = vec4(col, 1.0);
}
