// Tests: nested function with global-like pattern
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_time;

vec2 rotate2d(vec2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

float tile(vec2 p) {
    p = fract(p) - 0.5;
    float d = length(p);
    return smoothstep(0.4, 0.38, d);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0) - 0.5;
    uv = rotate2d(uv, u_time * 0.5);
    float pattern = tile(uv * 5.0);
    fragColor = vec4(vec3(pattern), 1.0);
}
