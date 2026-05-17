#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex function with multiple return paths
vec3 getColor(float t) {
    if (t < 0.25) return vec3(0.5, 0.0, 0.5) + t * 4.0;
    if (t < 0.5) return vec3(1.0, (t - 0.25) * 4.0, 0.0);
    if (t < 0.75) return vec3(1.0 - (t - 0.5) * 4.0, 1.0, (t - 0.5) * 4.0);
    return vec3(0.0, 1.0 - (t - 0.75) * 4.0, 1.0);
}

void main() {
    float t = uv.x;
    float intensity = uv.y;
    
    vec3 col = getColor(t) * intensity;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
