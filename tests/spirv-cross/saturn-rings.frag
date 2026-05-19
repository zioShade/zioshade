#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Saturn with rings and moons
void main() {
    // Deep space background
    vec3 col = vec3(0.01, 0.01, 0.03);
    
    // Stars
    float star = step(0.997, fract(sin(dot(floor(uv * 250.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.6, 0.65, 0.8);
    
    // Saturn position
    vec2 saturn = vec2(0.5, 0.5);
    vec2 p = uv - saturn;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Planet body (slightly elliptical for 3D feel)
    vec2 ep = p * vec2(1.0, 0.85);
    float er = length(ep);
    float planet = smoothstep(0.14, 0.135, er);
    
    // Planet bands (Jupiter-like horizontal stripes)
    float bands = sin(p.y * 25.0) * 0.5 + 0.5;
    bands = smoothstep(0.3, 0.7, bands) * 0.15;
    
    vec3 planet_col = vec3(0.75, 0.65, 0.4) + bands;
    col = mix(col, planet_col, planet);
    
    // Shadow on planet (from rings)
    float shadow = smoothstep(0.0, -0.02, p.y) * smoothstep(-0.08, -0.03, p.y) * planet;
    col = mix(col, planet_col * 0.5, shadow * 0.4);
    
    // Ring system (ellipse)
    float ring_a = 0.32; // semi-major
    float ring_b = 0.06; // semi-minor (tilted)
    float ring_dist = length(p * vec2(1.0 / ring_a, 1.0 / ring_b));
    
    // Multiple ring bands
    float ring_outer = smoothstep(1.3, 1.25, ring_dist) * (1.0 - smoothstep(1.1, 1.05, ring_dist));
    float ring_inner = smoothstep(1.0, 0.95, ring_dist) * (1.0 - smoothstep(0.75, 0.7, ring_dist));
    float ring_gap = 1.0 - smoothstep(1.05, 1.06, ring_dist) * (1.0 - smoothstep(1.1, 1.09, ring_dist));
    
    float ring = (ring_outer + ring_inner * 0.7) * ring_gap;
    
    // Ring color
    vec3 ring_col = vec3(0.7, 0.6, 0.45);
    
    // Ring behind planet (top half)
    float behind = step(0.0, p.y);
    float in_front = 1.0 - behind;
    
    // Only show ring behind planet in upper half
    float ring_behind = ring * behind;
    float ring_front = ring * in_front;
    
    // Draw ring behind planet first
    col = mix(col, ring_col, ring_behind);
    
    // Then planet on top
    col = mix(col, planet_col, planet);
    
    // Then ring in front (bottom half)
    col = mix(col, ring_col * 0.85, ring_front * (1.0 - planet));
    
    // Ring shadow on planet
    col = mix(col, planet_col * 0.5, shadow * 0.3);
    
    // Small moon
    vec2 moon_pos = vec2(0.78, 0.6);
    float moon_d = length(uv - moon_pos);
    float moon = smoothstep(0.02, 0.015, moon_d);
    float moon_shade = smoothstep(0.02, 0.0, moon_d);
    col = mix(col, vec3(0.6, 0.6, 0.65) * (0.3 + 0.7 * moon_shade), moon);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
