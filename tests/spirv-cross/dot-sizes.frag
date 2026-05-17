#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// OpDot with different vector sizes
void main() {
    float d2 = dot(vec2(uv), vec2(0.5, 0.3));
    float d3 = dot(vec3(uv, 0.5), vec3(1.0, 0.5, 0.3));
    float d4 = dot(vec4(uv, 0.5, 1.0), vec4(0.3, 0.5, 0.7, 0.2));
    
    vec3 col = vec3(d2, d3 * 0.5, d4 * 0.3);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
