#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test topiary garden with shaped bushes
float sdCircle(vec2 p, vec2 c, float r) {
    return length(p - c) - r;
}

float sdBox(vec2 p, vec2 c, vec2 b) {
    vec2 d = abs(p - c) - b;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

void main() {
    vec3 col = vec3(0.45, 0.65, 0.85); // sky
    
    // Ground
    float ground = smoothstep(0.45, 0.42, uv.y);
    col = mix(col, vec3(0.3, 0.5, 0.2), ground);
    
    // Topiary bushes (shaped spheres)
    // Round bush
    float d1 = sdCircle(uv, vec2(0.2, 0.45), 0.12);
    float bush1 = smoothstep(0.0, -0.01, d1);
    
    // Tall oval bush
    float d2 = sdCircle((uv - vec2(0.5, 0.48)) / vec2(1.0, 1.6), vec2(0.0), 0.08);
    float bush2 = smoothstep(0.0, -0.01, d2);
    
    // Square-cut bush
    float d3 = sdBox(uv, vec2(0.8, 0.43), vec2(0.08, 0.1));
    float bush3 = smoothstep(0.0, -0.01, d3);
    
    // Bush colors with shading
    vec3 bush_dark = vec3(0.1, 0.35, 0.1);
    vec3 bush_light = vec3(0.2, 0.55, 0.15);
    
    // Trunks
    float trunk1 = smoothstep(0.01, 0.0, abs(uv.x - 0.2)) * step(uv.y, 0.42) * step(0.3, uv.y);
    float trunk2 = smoothstep(0.01, 0.0, abs(uv.x - 0.5)) * step(uv.y, 0.35) * step(0.25, uv.y);
    float trunk3 = smoothstep(0.01, 0.0, abs(uv.x - 0.8)) * step(uv.y, 0.38) * step(0.3, uv.y);
    
    col = mix(col, bush_light, bush1);
    col = mix(col, bush_dark * 1.2, bush1 * step(0.5, uv.y));
    col = mix(col, bush_light * 0.9, bush2);
    col = mix(col, bush_dark, bush2 * step(0.55, uv.y));
    col = mix(col, bush_light, bush3);
    col = mix(col, bush_dark, bush3 * step(0.45, uv.y));
    
    col = mix(col, vec3(0.4, 0.3, 0.15), trunk1 + trunk2 + trunk3);
    
    // Path
    float path = smoothstep(0.02, 0.0, abs(uv.x - 0.5)) * ground;
    col = mix(col, vec3(0.6, 0.55, 0.45), path);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
