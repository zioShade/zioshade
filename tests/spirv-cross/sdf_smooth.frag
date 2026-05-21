#version 310 es
precision highp float;
out vec4 fragColor;

float sdCircle3(vec2 p, float r) { return length(p) - r; }
float opUnion2(float d1, float d2) { return min(d1, d2); }
float opSmooth2(float d1, float d2, float k) {
    float h = clamp(0.5 + 0.5*(d2-d1)/k, 0.0, 1.0);
    return mix(d2, d1, h) - k*h*(1.0-h);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float d1 = sdCircle3(uv - vec2(-0.3, 0.0), 0.3);
    float d2 = sdCircle3(uv - vec2(0.3, 0.0), 0.25);
    float d3 = sdCircle3(uv, 0.4);
    float d = opSmooth2(opUnion2(d1, d2), d3, 0.1);
    vec3 col = vec3(1.0) - sign(d) * vec3(0.3, 0.5, 0.7);
    col *= 1.0 - exp(-3.0 * abs(d));
    col *= 0.8 + 0.2 * cos(32.0 * d);
    fragColor = vec4(col, 1.0);
}
