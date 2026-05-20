#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Celtic knot pattern
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Interlocking loops
    float knot = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float offset = fi * 1.5708; // pi/2
        vec2 center = vec2(cos(offset), sin(offset)) * 0.3;
        float d = length(uv - center);
        float ring = smoothstep(0.25, 0.23, d) * (1.0 - smoothstep(0.18, 0.16, d));
        knot = max(knot, ring);
    }
    vec3 col = vec3(0.05, 0.2, 0.05) + vec3(0.6, 0.5, 0.3) * knot;
    fragColor = vec4(col, 1.0);
}
