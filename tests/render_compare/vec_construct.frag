#version 430
layout(location = 0) out vec4 FragColor;

// Test vector construction with mixed swizzles
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    vec4 c = vec4(uv, 0.5, 1.0);
    vec3 v1 = vec3(c.xy, c.z);
    vec3 v2 = vec3(c.x, c.yz);
    vec4 v3 = vec4(c.xy, c.z, c.w);
    FragColor = vec4(v1 + v2, v3.w) * 0.5;
}
