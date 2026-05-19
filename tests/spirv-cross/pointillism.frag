#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pointillism / dot painting effect
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv * 20.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Compute base color from smooth coordinates
    vec2 smooth_uv = uv;
    float h1 = hash(id);
    float h2 = hash(id + 100.0);
    float h3 = hash(id + 200.0);
    
    // Simulated landscape colors
    float y_band = smooth_uv.y;
    vec3 sky = vec3(0.4, 0.6, 0.9);
    vec3 grass = vec3(0.3, 0.6, 0.2);
    vec3 water = vec3(0.2, 0.4, 0.7);
    vec3 field = vec3(0.6, 0.55, 0.2);
    
    vec3 base_col;
    if (y_band > 0.7) base_col = sky;
    else if (y_band > 0.45) base_col = mix(field, grass, (y_band - 0.45) / 0.25);
    else base_col = mix(water, field, y_band / 0.45);
    
    // Vary color per dot
    base_col += (h1 - 0.5) * 0.15;
    
    // Dot shape: circle in center of cell
    vec2 center = vec2(0.5 + (h2 - 0.5) * 0.15, 0.5 + (h3 - 0.5) * 0.15);
    float d = length(fp - center);
    float dot_size = 0.3 + h1 * 0.15;
    float dot = smoothstep(dot_size, dot_size - 0.05, d);
    
    // Canvas texture
    vec3 canvas = vec3(0.95, 0.93, 0.88);
    
    vec3 col = mix(canvas, base_col, dot);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
