#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test persian rug pattern with nested geometry
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 6.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    float h = hash(id);
    
    // Diamond shape
    float diamond = abs(fp.x - 0.5) + abs(fp.y - 0.5);
    float border1 = smoothstep(0.48, 0.46, diamond) * (1.0 - smoothstep(0.44, 0.42, diamond));
    float fill = smoothstep(0.4, 0.38, diamond);
    
    // Inner star (8-pointed)
    float a = atan(fp.y - 0.5, fp.x - 0.5);
    float sr = length(fp - 0.5);
    float star = cos(a * 4.0) * 0.1 + 0.15;
    float star_fill = smoothstep(star, star - 0.02, sr);
    
    // Colors per tile
    vec3 border_col = vec3(0.7, 0.2, 0.1);
    vec3 fill_col = mix(vec3(0.2, 0.4, 0.6), vec3(0.6, 0.5, 0.2), h);
    vec3 star_col = vec3(0.9, 0.8, 0.4);
    
    vec3 col = vec3(0.12, 0.08, 0.06);
    col = mix(col, fill_col, fill);
    col = mix(col, border_col, border1);
    col = mix(col, star_col, star_fill * fill);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
