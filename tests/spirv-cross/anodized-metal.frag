#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test anodized metal surface
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Brushed metal direction
    float brushed = sin(r * 80.0) * 0.03;
    
    // Anodized color shift from viewing angle simulation
    float view_angle = dot(normalize(p + vec2(0.001)), vec2(0.3, 0.7));
    float hue = view_angle * 0.5 + 0.5;
    
    // Convert hue to metallic color
    vec3 col;
    if (hue < 0.3) col = vec3(0.5, 0.5, 0.55);
    else if (hue < 0.5) col = mix(vec3(0.5, 0.5, 0.55), vec3(0.3, 0.45, 0.6), (hue - 0.3) / 0.2);
    else if (hue < 0.7) col = mix(vec3(0.3, 0.45, 0.6), vec3(0.45, 0.4, 0.55), (hue - 0.5) / 0.2);
    else col = mix(vec3(0.45, 0.4, 0.55), vec3(0.5, 0.5, 0.55), (hue - 0.7) / 0.3);
    
    // Add brushed texture
    col += brushed;
    
    // Circular plate edge
    float edge = smoothstep(0.46, 0.44, r);
    float rim = smoothstep(0.44, 0.43, r) * (1.0 - smoothstep(0.42, 0.41, r));
    
    col *= edge;
    col += rim * 0.2;
    
    // Center bore hole
    float bore = smoothstep(0.06, 0.05, r);
    col *= 1.0 - bore;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
