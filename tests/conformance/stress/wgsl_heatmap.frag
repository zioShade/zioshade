// Test: complex control flow with early exit
#version 450

layout(location = 0) out vec4 fragColor;

vec3 heatColor(float t) {
    if (t < 0.0) return vec3(0.0, 0.0, 0.0);
    if (t < 0.25) return vec3(t * 4.0, 0.0, 0.0);
    if (t < 0.5) return vec3(1.0, (t - 0.25) * 4.0, 0.0);
    if (t < 0.75) return vec3(1.0, 1.0, (t - 0.5) * 4.0);
    if (t <= 1.0) return vec3(1.0, 1.0, 1.0);
    return vec3(1.0, 1.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float val = length(uv - 0.5) * 2.0;
    vec3 color = heatColor(val);
    fragColor = vec4(color, 1.0);
}
