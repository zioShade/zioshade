// Tests: conditional with compound logical expression
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_time;

void main() {
    float t = fract(u_time);
    bool a = t > 0.2;
    bool b = t < 0.8;
    bool c = t > 0.5;

    vec3 color;
    if (a && b) {
        color = vec3(1.0, 0.5, 0.0);
        if (!c) {
            color *= 0.5;
        }
    } else if (a || c) {
        color = vec3(0.0, 0.5, 1.0);
    } else {
        color = vec3(0.2);
    }
    fragColor = vec4(color, 1.0);
}
