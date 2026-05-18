#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test ocean wave pattern
void main() {
    vec2 p = uv * 6.0;
    
    float wave1 = sin(p.x * 1.5 + sin(p.y * 0.8) * 2.0);
    float wave2 = sin(p.y * 1.2 + sin(p.x * 0.6) * 1.5);
    float wave3 = sin((p.x + p.y) * 0.8);
    
    float wave = (wave1 + wave2 + wave3) / 3.0;
    wave = wave * 0.5 + 0.5;
    
    // Ocean colors
    vec3 deep = vec3(0.0, 0.1, 0.3);
    vec3 shallow = vec3(0.1, 0.4, 0.6);
    vec3 foam = vec3(0.8, 0.9, 1.0);
    
    vec3 col = mix(deep, shallow, wave);
    col = mix(col, foam, smoothstep(0.75, 0.85, wave));
    
    // Depth gradient
    col *= 0.5 + uv.y * 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
