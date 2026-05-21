#version 310 es
precision highp float;
out vec4 fragColor;

// Test: inverse square root and other math builtins
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float inv = inversesqrt(r * r + 0.01);
    float exp_val = exp(-r * 2.0);
    float log_val = log(r + 1.0);
    vec3 col = vec3(inv * 0.3, exp_val * 0.7, log_val * 0.2);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
