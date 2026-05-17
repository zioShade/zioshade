#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 2D SDF operations: union, intersection, subtraction
float sdCircle(vec2 p, float r) { return length(p) - r; }
float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float opUnion(float a, float b) { return min(a, b); }
float opSub(float a, float b) { return max(-a, b); }
float opInter(float a, float b) { return max(a, b); }

void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    float circle = sdCircle(p - vec2(-0.5, 0.0), 0.7);
    float box = sdBox(p - vec2(0.5, 0.0), vec2(0.5));
    
    float u = opUnion(circle, box);
    float s = opSub(circle, box);  // box minus circle
    float inter = opInter(circle, box);
    
    float col = 1.0 - smoothstep(0.0, 0.02, s);
    vec3 color = vec3(col * 0.8, col * 0.5, col * 0.3);
    
    fragColor = vec4(color, 1.0);
}
