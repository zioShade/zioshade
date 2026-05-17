#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test mod with vec2
void main() {
    vec2 p = mod(uv * 5.0, vec2(1.0));
    
    float d = length(p - 0.5);
    float col = smoothstep(0.3, 0.28, d);
    
    vec3 color = col * vec3(0.8, 0.5, 0.3);
    fragColor = vec4(color, 1.0);
}
