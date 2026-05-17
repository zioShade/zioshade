#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test starfield with layered random dots
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec3 col = vec3(0.01, 0.01, 0.03);
    
    // Multiple layers of stars at different densities
    for (int layer = 0; layer < 3; layer++) {
        float scale = 20.0 + float(layer) * 30.0;
        vec2 p = uv * scale;
        vec2 id = floor(p);
        vec2 fp = fract(p);
        
        float h = hash(id + float(layer) * 100.0);
        float h2 = hash(id * 1.7 + float(layer) * 200.0);
        
        vec2 star_pos = vec2(h, h2);
        float d = length(fp - star_pos);
        
        float brightness = smoothstep(0.05, 0.0, d) * hash(id + 0.5);
        float size = 0.02 + h * 0.03;
        float glow = exp(-d * d / (size * size)) * 0.5;
        
        vec3 star_col = mix(vec3(0.8, 0.9, 1.0), vec3(1.0, 0.8, 0.6), h2);
        col += (brightness + glow) * star_col;
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
