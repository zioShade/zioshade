#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Chromatic dispersion simulation
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);
    
    // Different wavelengths refract differently
    float red_r = r + sin(angle * 6.0) * 0.05;
    float green_r = r + sin(angle * 6.0 + 2.094) * 0.05;
    float blue_r = r + sin(angle * 6.0 + 4.189) * 0.05;
    
    // Rainbow rings
    float red = smoothstep(0.02, 0.0, abs(red_r - 0.5));
    float green = smoothstep(0.02, 0.0, abs(green_r - 0.5));
    float blue = smoothstep(0.02, 0.0, abs(blue_r - 0.5));
    
    vec3 col = vec3(red, green, blue);
    col *= smoothstep(0.9, 0.3, r);
    
    fragColor = vec4(col, 1.0);
}
