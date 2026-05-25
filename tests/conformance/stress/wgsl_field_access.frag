// Tests: vec2/vec3 field access patterns
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec3 v = vec3(1.0, 2.0, 3.0);
    float x = v.x;
    float y = v.y;
    float z = v.z;
    vec2 xy = v.xy;
    vec2 yz = v.yz;
    vec3 combined = vec3(xy, z) + vec3(x, yz);
    fragColor = vec4(combined, 1.0);
}
