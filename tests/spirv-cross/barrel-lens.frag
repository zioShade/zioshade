#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test barrel/fisheye lens distortion
void main() {
    vec2 p = uv - 0.5;
    float r2 = dot(p, p);
    
    // Barrel distortion
    float distortion = 1.0 + r2 * 1.5;
    vec2 distorted = p * distortion + 0.5;
    
    // Valid region check
    float valid = step(0.0, distorted.x) * step(distorted.x, 1.0) *
                  step(0.0, distorted.y) * step(distorted.y, 1.0);
    
    // Grid pattern in distorted space
    float grid_x = smoothstep(0.02, 0.03, abs(fract(distorted.x * 10.0) - 0.5) - 0.45);
    float grid_y = smoothstep(0.02, 0.03, abs(fract(distorted.y * 10.0) - 0.5) - 0.45);
    float grid = 1.0 - grid_x * grid_y;
    
    // Color based on distortion amount
    vec3 col = vec3(0.0);
    col += valid * grid * mix(vec3(0.3, 0.5, 0.8), vec3(0.8, 0.3, 0.3), r2 * 3.0);
    
    // Lens border
    float border = smoothstep(0.48, 0.47, length(uv - 0.5));
    col = mix(vec3(0.1), col, border);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
