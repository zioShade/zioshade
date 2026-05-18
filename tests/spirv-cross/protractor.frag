#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test protractor/angle measurement visualization
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Degree markings
    float deg = a * 57.2958; // radians to degrees
    
    // Tick marks every 30 degrees
    float tick = 0.0;
    for (int i = 0; i < 12; i++) {
        float angle = float(i) * 0.5236; // 30 degrees in radians
        float diff = abs(a - angle);
        diff = min(diff, 6.2832 - diff);
        float tick_r1 = 0.35;
        float tick_r2 = 0.4;
        float in_range = step(tick_r1, r) * step(r, tick_r2);
        tick += smoothstep(0.02, 0.005, diff) * in_range;
    }
    
    // Concentric circles
    float circles = 0.0;
    for (int i = 1; i <= 4; i++) {
        float cr = float(i) * 0.1;
        circles += smoothstep(0.003, 0.0, abs(r - cr));
    }
    
    // Filled sector
    float sector = step(a, 1.047) * step(0.0, a) * step(r, 0.3);
    
    vec3 col = vec3(0.1);
    col += sector * vec3(0.2, 0.3, 0.5);
    col += circles * vec3(0.3);
    col += tick * vec3(0.8, 0.6, 0.2);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
