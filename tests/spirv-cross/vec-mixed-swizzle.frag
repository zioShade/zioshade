#version 450

layout(location = 0) out vec4 fragColor;

// Test vec3 construction with mixed swizzle + scalars
void main() {
    vec4 c = vec4(0.2, 0.4, 0.6, 0.8);
    vec3 v1 = vec3(c.xy, c.z);
    vec3 v2 = vec3(c.x, c.yz);
    vec4 v3 = vec4(c.xy, c.z, 1.0);
    vec4 v4 = vec4(1.0, c.yz, c.w);
    fragColor = vec4(v1 + v2, v3.w * v4.x);
}
