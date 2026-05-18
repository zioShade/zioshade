#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test parquet wood floor pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec2 p = uv * 10.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = hash(id);
    
    // Alternating diagonal direction (herringbone-like)
    float flip = mod(id.x + id.y, 2.0);
    float local_u = mix(fp.x, fp.y, flip);
    float local_v = mix(fp.y, fp.x, flip);
    
    // Wood grain along local_u direction
    float grain = sin((local_u + h * 3.0) * 15.0 + sin(local_v * 5.0) * 0.5) * 0.5 + 0.5;
    
    // Plank gap
    float gap = step(local_u, 0.03) + step(0.97, local_u);
    
    // Wood colors per plank
    vec3 wood_a = mix(vec3(0.55, 0.4, 0.25), vec3(0.7, 0.5, 0.3), h);
    vec3 wood_b = wood_a * 0.85;
    vec3 col = mix(wood_b, wood_a, grain);
    
    // Gap darkening
    col = mix(col, vec3(0.15), gap);
    
    // Subtle specular variation
    col *= 0.9 + 0.1 * smoothstep(0.3, 0.7, grain);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
