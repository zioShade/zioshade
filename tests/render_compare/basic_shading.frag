#version 430
layout(location = 0) out vec4 FragColor;

// Test: face normal-based shading
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 normal = normalize(vec3(uv * 2.0 - 1.0, 0.5));
    vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
    float diff = max(dot(normal, lightDir), 0.0);
    vec3 col = vec3(0.6, 0.7, 0.9) * (diff * 0.7 + 0.3);
    FragColor = vec4(col, 1.0);
}
