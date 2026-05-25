// Tests: conditional discard with early exit
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float x = 0.5;
    if (x < 0.25) discard;
    vec3 color = vec3(x);
    if (x > 0.75) {
        fragColor = vec4(color * 2.0, 1.0);
        return;
    }
    fragColor = vec4(color, 1.0);
}
