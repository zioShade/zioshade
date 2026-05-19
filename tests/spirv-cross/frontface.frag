#version 450

// Test: face culling via gl_FrontFacing
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    bool front = gl_FrontFacing;
    vec3 col = front ? vec3(uv, 0.5) : vec3(1.0 - uv, 0.5);
    gl_FragColor = vec4(col, 1.0);
}
