#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test distance field text rendering simulation
float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

void main() {
    vec2 p = uv * 10.0 - 5.0;
    
    // Draw "H" shape
    float d = 1.0;
    d = min(d, sdSegment(p, vec2(-2, -1), vec2(-2, 1)));  // left vertical
    d = min(d, sdSegment(p, vec2(2, -1), vec2(2, 1)));     // right vertical
    d = min(d, sdSegment(p, vec2(-2, 0), vec2(2, 0)));      // horizontal
    
    float letter = smoothstep(0.1, 0.08, d);
    
    vec3 col = mix(vec3(0.05), vec3(0.3, 0.6, 0.9), letter);
    fragColor = vec4(col, 1.0);
}
