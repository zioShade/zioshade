#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test solar system orrery
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    
    // Dark space background
    vec3 col = vec3(0.02, 0.02, 0.05);
    
    // Stars
    float star = step(0.998, fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.7, 0.75, 0.9);
    
    // Sun at center
    float sun = smoothstep(0.04, 0.035, r);
    float sun_glow = exp(-r * r * 30.0) * 0.3;
    col += sun * vec3(1.0, 0.9, 0.3);
    col += sun_glow * vec3(1.0, 0.7, 0.2);
    
    // Planets in orbit
    float orbits[6];
    float sizes[6];
    
    // Mercury
    float d1 = length(p - vec2(0.08, 0.0));
    float mercury = smoothstep(0.012, 0.009, d1);
    float mercury_orbit = smoothstep(0.002, 0.001, abs(r - 0.08));
    col += mercury * vec3(0.7, 0.6, 0.5);
    col += mercury_orbit * vec3(0.15, 0.15, 0.2);
    
    // Venus
    float d2 = length(p - vec2(-0.12, 0.05));
    float venus = smoothstep(0.016, 0.013, d2);
    float venus_orbit = smoothstep(0.002, 0.001, abs(r - 0.14));
    col += venus * vec3(0.9, 0.8, 0.5);
    col += venus_orbit * vec3(0.15, 0.15, 0.2);
    
    // Earth
    float d3 = length(p - vec2(0.18, -0.08));
    float earth = smoothstep(0.018, 0.015, d3);
    float earth_orbit = smoothstep(0.002, 0.001, abs(r - 0.2));
    col += earth * vec3(0.2, 0.5, 0.8);
    col += earth_orbit * vec3(0.15, 0.15, 0.2);
    
    // Mars
    float d4 = length(p - vec2(-0.25, 0.05));
    float mars = smoothstep(0.015, 0.012, d4);
    float mars_orbit = smoothstep(0.002, 0.001, abs(r - 0.26));
    col += mars * vec3(0.8, 0.3, 0.2);
    col += mars_orbit * vec3(0.15, 0.15, 0.2);
    
    // Jupiter
    float d5 = length(p - vec2(0.32, 0.1));
    float jupiter = smoothstep(0.028, 0.024, d5);
    float jupiter_orbit = smoothstep(0.002, 0.001, abs(r - 0.35));
    col += jupiter * vec3(0.8, 0.7, 0.5);
    col += jupiter_orbit * vec3(0.15, 0.15, 0.2);
    
    // Saturn (with ring)
    vec2 sp = p - vec2(-0.38, -0.08);
    float sd = length(sp);
    float saturn = smoothstep(0.024, 0.02, sd);
    float ring_a = atan(sp.y, sp.x);
    float ring_r = length(sp);
    float saturn_ring = smoothstep(0.035, 0.033, ring_r) * (1.0 - smoothstep(0.028, 0.026, ring_r));
    float saturn_orbit = smoothstep(0.002, 0.001, abs(r - 0.42));
    col += saturn * vec3(0.85, 0.75, 0.5);
    col += saturn_ring * vec3(0.7, 0.65, 0.5) * 0.6;
    col += saturn_orbit * vec3(0.15, 0.15, 0.2);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
