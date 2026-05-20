#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x * 0.01;
    // Chain of step and smoothstep
    float s1 = step(0.2, x);
    float s2 = step(0.4, x);
    float s3 = smoothstep(0.3, 0.7, x);
    float s4 = smoothstep(0.5, 0.9, x);
    float combined = s1 * s2 + s3 * s4;
    float clamped = clamp(combined, 0.0, 1.0);
    float mixed = mix(0.2, 0.8, clamped);
    fragColor = vec4(mixed);
}
