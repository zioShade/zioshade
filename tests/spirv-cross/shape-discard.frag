#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test early discard in function
bool isInShape(vec2 p, float r) {
    if (length(p) > r) return false;
    return true;
}

void main() {
    // Discard outside shape
    if (!isInShape(uv - vec2(0.3, 0.5), 0.2) &&
        !isInShape(uv - vec2(0.7, 0.5), 0.2)) {
        fragColor = vec4(0.05, 0.05, 0.08, 1.0);
        return;
    }
    
    // Color inside shapes
    float d1 = length(uv - vec2(0.3, 0.5));
    float d2 = length(uv - vec2(0.7, 0.5));
    
    vec3 col;
    if (d1 < 0.2) col = vec3(0.8, 0.3, 0.2);
    else col = vec3(0.2, 0.5, 0.9);
    
    col *= 0.7 + 0.3 * sin(d1 * 20.0 + d2 * 15.0);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
