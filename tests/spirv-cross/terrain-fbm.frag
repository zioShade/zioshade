#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test terrain heightmap with contour coloring
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += noise(p) * amp;
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    float h = fbm(uv * 4.0);
    
    // Height-based coloring
    vec3 water = vec3(0.1, 0.3, 0.6);
    vec3 sand = vec3(0.8, 0.75, 0.5);
    vec3 grass = vec3(0.2, 0.6, 0.15);
    vec3 rock = vec3(0.5, 0.45, 0.4);
    vec3 snow = vec3(0.95, 0.95, 1.0);
    
    vec3 col;
    if (h < 0.3) col = water;
    else if (h < 0.35) col = mix(water, sand, (h - 0.3) / 0.05);
    else if (h < 0.45) col = sand;
    else if (h < 0.55) col = grass;
    else if (h < 0.7) col = mix(grass, rock, (h - 0.55) / 0.15);
    else if (h < 0.85) col = rock;
    else col = mix(rock, snow, (h - 0.85) / 0.15);
    
    fragColor = vec4(col, 1.0);
}
