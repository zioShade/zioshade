#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test depth output with gl_FragDepth
void main() {
    float depth = 0.5 + 0.5 * sin(uv.x * 3.14159);
    gl_FragDepth = depth;
    vec3 color = vec3(depth, depth * 0.5, 1.0 - depth);
    fragColor = vec4(color, 1.0);
}
