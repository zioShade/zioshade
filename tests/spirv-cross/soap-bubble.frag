#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test soap bubble thin-film interference
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Bubble shape
    float bubble = smoothstep(0.45, 0.44, r);
    
    // Film thickness varies across surface
    float thickness = sin(a * 3.0 + r * 10.0) * 0.5 + 0.5;
    thickness = mix(0.3, 1.0, thickness);
    
    // Thin-film interference colors (simplified)
    float phase = thickness * 6.28 * 2.0;
    float red = sin(phase) * 0.5 + 0.5;
    float green = sin(phase + 2.094) * 0.5 + 0.5;
    float blue = sin(phase + 4.188) * 0.5 + 0.5;
    
    vec3 iridescent = vec3(red, green, blue);
    
    // Fresnel-like edge brightening
    float fresnel = pow(1.0 - smoothstep(0.0, 0.44, r), 2.0);
    
    // Specular highlight
    vec2 light = vec2(0.3, 0.3);
    float spec = exp(-length(p - light) * length(p - light) * 30.0);
    
    vec3 col = vec3(0.05);
    col += bubble * (iridescent * 0.4 + fresnel * 0.3);
    col += spec * bubble * 0.8;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
