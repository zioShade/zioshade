#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    float t = uv.x;
    // Hermite interpolation
    float h = t * t * (3.0 - 2.0 * t);
    // Sigmoid
    float s = 1.0 / (1.0 + exp(-10.0 * (t - 0.5)));
    // Smooth pulse
    float w = 0.1;
    float pulse = smoothstep(0.4 - w, 0.4, t) - smoothstep(0.6 - w, 0.6, t);
    fragColor = vec4(h, s, pulse, 1.0);
}
