#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test switch with default and multiple cases
void main() {
    int x = int(uv.x * 5.0);
    vec3 col = vec3(0.0);
    
    switch (x) {
        case 0: col = vec3(1.0, 0.0, 0.0); break;
        case 1: col = vec3(0.0, 1.0, 0.0); break;
        case 2: col = vec3(0.0, 0.0, 1.0); break;
        case 3: col = vec3(1.0, 1.0, 0.0); break;
        case 4: col = vec3(1.0, 0.0, 1.0); break;
        default: col = vec3(0.5); break;
    }
    
    col *= 0.5 + 0.5 * sin(uv.y * 3.14);
    fragColor = vec4(col, 1.0);
}
