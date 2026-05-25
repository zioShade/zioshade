// Tests: multiple function calls returning float
#version 450
layout(location = 0) out vec4 fragColor;

float noise(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}

float fbm(float x) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += noise(x) * amp;
        x *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    float n = fbm(3.7);
    fragColor = vec4(vec3(n), 1.0);
}
