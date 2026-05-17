#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test glass refraction pattern
void main() {
    vec2 p = uv - 0.5;
    float d = length(p);
    
    // Refraction offset based on distance from center
    float angle = atan(p.y, p.x);
    float refract_strength = exp(-d * d * 8.0) * 0.3;
    
    vec2 refracted_uv = uv + vec2(cos(angle + 1.0), sin(angle + 1.0)) * refract_strength;
    
    // Checkerboard behind glass
    float check = mod(floor(refracted_uv.x * 10.0) + floor(refracted_uv.y * 10.0), 2.0);
    vec3 bg = mix(vec3(0.2, 0.5, 0.3), vec3(0.5, 0.8, 0.4), check);
    
    // Glass tint
    float glass = smoothstep(0.5, 0.45, d);
    vec3 glass_col = vec3(0.7, 0.85, 0.95);
    
    // Fresnel-like edge
    float fresnel = pow(1.0 - smoothstep(0.0, 0.45, d), 3.0);
    
    vec3 col = mix(bg, glass_col * bg, glass * (0.5 + fresnel * 0.5));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
