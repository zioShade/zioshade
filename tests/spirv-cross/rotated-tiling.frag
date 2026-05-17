#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Repeated tiling with rotation
void main() {
    vec2 p = uv * 6.0;
    vec2 cell = floor(p);
    vec2 fp = fract(p);
    
    // Rotate each cell differently
    float hash_val = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    float angle = hash_val * 3.14;
    float c = cos(angle);
    float s = sin(angle);
    
    vec2 rotated = vec2(c * (fp.x - 0.5) - s * (fp.y - 0.5),
                        s * (fp.x - 0.5) + c * (fp.y - 0.5)) + 0.5;
    
    float d = length(rotated - 0.5);
    float col = smoothstep(0.35, 0.3, d);
    
    vec3 color = col * vec3(hash_val, 1.0 - hash_val, 0.5);
    fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
