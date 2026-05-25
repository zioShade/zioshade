// Tests: complex conditional with float comparison chain
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_val;

void main() {
    vec3 color;
    if (u_val < 0.25) {
        color = vec3(0.0, 0.0, 1.0);
    } else if (u_val < 0.5) {
        color = vec3(0.0, 1.0, 0.0);
    } else if (u_val < 0.75) {
        color = vec3(1.0, 1.0, 0.0);
    } else {
        color = vec3(1.0, 0.0, 0.0);
    }
    float brightness = dot(color, vec3(0.299, 0.587, 0.114));
    fragColor = vec4(color * brightness, 1.0);
}
