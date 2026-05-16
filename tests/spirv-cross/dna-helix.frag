#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// DNA double helix pattern
void main() {
    float x = uv.x;
    float y = uv.y * 6.28318 * 3.0;
    
    float helix1 = sin(y) * 0.15 + 0.5;
    float helix2 = sin(y + 3.14159) * 0.15 + 0.5;
    
    float d1 = abs(x - helix1);
    float d2 = abs(x - helix2);
    
    float strand1 = smoothstep(0.02, 0.0, d1);
    float strand2 = smoothstep(0.02, 0.0, d2);
    
    // Cross bars between helices
    float bar_y = fract(y / 3.14159);
    float bar = smoothstep(0.1, 0.0, bar_y) * step(d1 + d2, 0.32);
    
    vec3 col = vec3(0.0);
    col += vec3(0.2, 0.4, 0.9) * strand1;
    col += vec3(0.9, 0.3, 0.2) * strand2;
    col += vec3(0.5, 0.5, 0.5) * bar * 0.5;
    
    fragColor = vec4(col, 1.0);
}
