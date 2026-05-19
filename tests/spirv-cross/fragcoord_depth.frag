#version 450

// Test gl_FragCoord.z (depth), and gl_FrontFacing
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float depth = gl_FragCoord.z;
    bool front = gl_FrontFacing;
    float f = front ? 1.0 : 0.5;
    vec3 col = vec3(uv, depth) * f;
    gl_FragColor = vec4(col, 1.0);
}
