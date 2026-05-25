// Tests: select/ternary with complex types
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = vec2(0.5, 0.5);
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = (uv.x > 0.5) ? a : b;
    vec3 d = mix(c, vec3(0.5), step(0.3, uv.y));
    fragColor = vec4(d, 1.0);
}
