// Tests: function with 4 parameters
#version 450
layout(location = 0) out vec4 fragColor;

vec4 blend(vec4 base, vec4 overlay, float opacity, int mode) {
    if (mode == 0) {
        return mix(base, overlay, opacity);
    } else {
        return base + overlay * opacity;
    }
}

void main() {
    vec4 a = vec4(0.5, 0.3, 0.1, 1.0);
    vec4 b = vec4(0.2, 0.6, 0.8, 1.0);
    vec4 result = blend(a, b, 0.7, 1);
    fragColor = result;
}
