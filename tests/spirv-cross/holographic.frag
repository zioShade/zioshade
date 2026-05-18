#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test holographic/rainbow reflection effect
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Multiple overlapping gratings
    float g1 = sin(p.x * 40.0 + p.y * 20.0);
    float g2 = sin(p.x * 20.0 - p.y * 40.0);
    float g3 = sin((p.x + p.y) * 30.0);
    
    float grating = (g1 + g2 + g3) / 3.0;
    
    // Rainbow based on grating + angle
    float hue = grating * 0.3 + a / 6.28 + 0.5;
    hue = fract(hue);
    
    // HSV to RGB
    float h = hue * 6.0;
    float f = fract(h);
    vec3 rainbow;
    if (h < 1.0) rainbow = vec3(1.0, f, 0.0);
    else if (h < 2.0) rainbow = vec3(1.0 - f, 1.0, 0.0);
    else if (h < 3.0) rainbow = vec3(0.0, 1.0, f);
    else if (h < 4.0) rainbow = vec3(0.0, 1.0 - f, 1.0);
    else if (h < 5.0) rainbow = vec3(f, 0.0, 1.0);
    else rainbow = vec3(1.0, 0.0, 1.0 - f);
    
    // Metallic base
    vec3 metal = vec3(0.6, 0.6, 0.65);
    float blend = 0.3 + 0.4 * smoothstep(0.5, 0.1, r);
    
    vec3 col = mix(metal, rainbow, blend);
    col *= 0.5 + 0.5 * smoothstep(0.55, 0.2, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
