#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test topographic map contour lines
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

void main() {
    float h = noise(uv * 4.0) * 0.5 + noise(uv * 8.0) * 0.3 + noise(uv * 2.0) * 0.2;
    
    // Contour lines
    float contour = abs(fract(h * 10.0) - 0.5) * 2.0;
    float line = smoothstep(0.05, 0.02, contour);
    
    // Height-based coloring
    vec3 low = vec3(0.2, 0.5, 0.2);
    vec3 mid = vec3(0.6, 0.5, 0.2);
    vec3 high = vec3(0.9, 0.9, 0.9);
    
    vec3 col;
    if (h < 0.35) col = low;
    else if (h < 0.65) col = mid;
    else col = high;
    
    col = mix(col, vec3(0.1), line);
    
    fragColor = vec4(col, 1.0);
}
