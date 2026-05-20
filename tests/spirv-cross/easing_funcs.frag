#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    float t = uv.x;
    // Easing functions
    float ease_in = t * t;
    float ease_out = 1.0 - (1.0 - t) * (1.0 - t);
    float ease_in_out = t < 0.5 ? 2.0 * t * t : 1.0 - pow(-2.0 * t + 2.0, 2.0) / 2.0;
    float elastic = sin(-13.0 * 3.14159 * (t + 1.0)) * pow(2.0, -10.0 * t) + 1.0;
    float bounce = abs(sin(t * 3.14159 * 3.0)) * (1.0 - t);
    fragColor = vec4(ease_in, ease_out, ease_in_out, 1.0);
}
