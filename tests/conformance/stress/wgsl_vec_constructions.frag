// Tests: multiple vec2/vec3/vec4 constructions
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.3;
    float y = 0.7;
    vec2 a = vec2(x, y);
    vec3 b = vec3(a, 0.5);
    vec4 c = vec4(b.xy, b.z, 1.0);
    vec4 d = vec4(c.xyz * 2.0, c.w);
    fragColor = d;
}
