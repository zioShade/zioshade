#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test opalescent / opal gemstone effect
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Base opal sheen from multiple layers
    float layer1 = sin(r * 20.0 + a * 3.0) * 0.5 + 0.5;
    float layer2 = sin(r * 15.0 - a * 5.0 + 1.0) * 0.5 + 0.5;
    float layer3 = sin(r * 25.0 + a * 2.0 + 2.0) * 0.5 + 0.5;
    
    // Combine layers with color shifts
    vec3 col1 = vec3(0.8, 0.3, 0.5) * layer1;
    vec3 col2 = vec3(0.3, 0.5, 0.9) * layer2;
    vec3 col3 = vec3(0.3, 0.9, 0.6) * layer3;
    
    vec3 col = (col1 + col2 + col3) * 0.6;
    
    // Pearlescent white base
    vec3 pearl = vec3(0.9, 0.88, 0.92);
    float pearl_blend = 0.4 + 0.3 * smoothstep(0.3, 0.0, r);
    col = mix(col, pearl * col * 2.0, pearl_blend);
    
    // Cabochon shape (domed)
    float edge = smoothstep(0.45, 0.42, r);
    col *= edge;
    
    // Highlight
    vec2 hl = p - vec2(-0.1, -0.1);
    float highlight = exp(-dot(hl, hl) * 20.0) * 0.6;
    col += highlight;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
