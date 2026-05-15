#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

vec3 heatColor(float t) {
    t = clamp(t, 0.0, 1.0);
    return vec3(
        min(1.0, t * 3.0),
        max(0.0, min(1.0, t * 3.0 - 1.0)),
        max(0.0, t * 3.0 - 2.0)
    );
}

void main() {
    float d = length(uv - vec2(0.5));
    vec3 c = heatColor(1.0 - d * 2.0);
    fragColor = vec4(c, 1.0);
}
