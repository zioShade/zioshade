#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test rainbow arc in sky
void main() {
    vec2 p = uv - vec2(0.5, -0.3);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sky gradient with rain clouds
    vec3 sky = mix(vec3(0.5, 0.55, 0.65), vec3(0.3, 0.4, 0.55), uv.y);
    
    // Dark rain cloud
    float cloud = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 cp = uv - vec2(0.1 + fi * 0.12, 0.8 - sin(fi * 1.5) * 0.05);
        float cd = length(cp * vec2(1.0, 1.5));
        cloud += smoothstep(0.08, 0.05, cd);
    }
    cloud = min(cloud, 1.0);
    sky = mix(sky, vec3(0.4, 0.42, 0.45), cloud);
    
    vec3 col = sky;
    
    // Rainbow: multiple concentric arcs
    float rainbow_r = 0.55;
    float band_width = 0.012;
    
    vec3 colors[7];
    colors[0] = vec3(0.8, 0.0, 0.0);   // red
    colors[1] = vec3(1.0, 0.5, 0.0);   // orange
    colors[2] = vec3(1.0, 1.0, 0.0);   // yellow
    colors[3] = vec3(0.0, 0.8, 0.0);   // green
    colors[4] = vec3(0.0, 0.4, 1.0);   // blue
    colors[5] = vec3(0.3, 0.0, 0.7);   // indigo
    colors[6] = vec3(0.5, 0.0, 0.5);   // violet
    
    for (int i = 0; i < 7; i++) {
        float band_r = rainbow_r - float(i) * band_width;
        float band = smoothstep(band_width * 0.6, band_width * 0.3, abs(r - band_r));
        // Only draw in upper arc
        float arc = step(0.1, a) * smoothstep(3.04, 3.0, a);
        col += band * colors[i] * arc * 0.6;
    }
    
    // Secondary (fainter) rainbow
    float secondary_r = rainbow_r + 0.09;
    for (int i = 0; i < 7; i++) {
        float band_r = secondary_r + float(i) * band_width * 0.8;
        float band = smoothstep(band_width * 0.5, band_width * 0.2, abs(r - band_r));
        float arc = step(0.1, a) * smoothstep(3.04, 3.0, a);
        col += band * colors[6 - i] * arc * 0.2;
    }
    
    // Ground / grass
    float ground = step(uv.y, 0.12);
    vec3 grass = vec3(0.2, 0.4, 0.15);
    col = mix(col, grass, ground);
    
    // Wet ground reflection
    float wet = ground * smoothstep(0.12, 0.05, uv.y);
    col = mix(col, sky * 0.3, wet * 0.4);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
