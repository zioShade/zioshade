#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test spirograph pattern (hypotrochoid curves)
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Spirograph: multiple overlapping sinusoidal curves
    float pattern = 0.0;
    for (int i = 0; i < 7; i++) {
        float fi = float(i);
        float R = 0.3;
        float rr = 0.1 + fi * 0.01;
        float d = R - rr;
        float t = a * (1.0 + fi * 0.5);
        float x = d * cos(t) + rr * cos(d / rr * t);
        float y = d * sin(t) - rr * sin(d / rr * t);
        float dist = length(p - vec2(x, y) * 0.8);
        pattern += smoothstep(0.008, 0.003, dist);
    }
    
    // Color by angle for rainbow effect
    float hue = a / 6.2832 + 0.5;
    hue = fract(hue);
    float h6 = hue * 6.0;
    float f = fract(h6);
    vec3 rainbow;
    if (h6 < 1.0) rainbow = vec3(1.0, f, 0.0);
    else if (h6 < 2.0) rainbow = vec3(1.0 - f, 1.0, 0.0);
    else if (h6 < 3.0) rainbow = vec3(0.0, 1.0, f);
    else if (h6 < 4.0) rainbow = vec3(0.0, 1.0 - f, 1.0);
    else if (h6 < 5.0) rainbow = vec3(f, 0.0, 1.0);
    else rainbow = vec3(1.0, 0.0, 1.0 - f);
    
    vec3 col = vec3(0.02);
    col += min(pattern, 1.0) * rainbow;
    
    // Center glow
    col += exp(-r * r * 20.0) * 0.05;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
