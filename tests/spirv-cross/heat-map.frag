#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Heat map / thermal visualization
void main() {
    float val = length(uv - 0.5) * 2.0;
    
    vec3 col;
    if (val < 0.25) {
        col = mix(vec3(0.0, 0.0, 0.5), vec3(0.0, 0.0, 1.0), val / 0.25);
    } else if (val < 0.5) {
        col = mix(vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 0.0), (val - 0.25) / 0.25);
    } else if (val < 0.75) {
        col = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 1.0, 0.0), (val - 0.5) / 0.25);
    } else {
        col = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (val - 0.75) / 0.25);
    }
    
    fragColor = vec4(col, 1.0);
}
