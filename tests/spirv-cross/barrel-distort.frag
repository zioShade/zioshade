#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test length-based UV distortion
void main() {
    vec2 p = uv - 0.5;
    float d = length(p);
    
    // Barrel distortion
    float distortion = 1.0 + d * d * 2.0;
    vec2 distorted = p * distortion + 0.5;
    
    // Clamp to valid range
    float valid = step(0.0, distorted.x) * step(distorted.x, 1.0) *
                  step(0.0, distorted.y) * step(distorted.y, 1.0);
    
    // Checkerboard in distorted space
    float check = mod(floor(distorted.x * 10.0) + floor(distorted.y * 10.0), 2.0);
    
    vec3 col = vec3(check * 0.6 + 0.2) * valid;
    fragColor = vec4(col, 1.0);
}
