// Tests: vec3 initialization from scalar + vec2
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    vec2 a = vec2(0.5, 0.7);
    float b = 0.3;
    vec3 combined = vec3(a, b);
    vec3 reversed = vec3(b, a);
    fragColor = vec4(combined + reversed * 0.5, 1.0);
}
