#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Celtic spiral pattern
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Triple spiral (triskelion)
    float spiral = 0.0;
    for (int i = 0; i < 3; i++) {
        float offset = float(i) * 2.094;
        float sa = a - offset;
        float sr = 0.15 + sa * 0.08;
        float d = abs(r - sr);
        spiral = max(spiral, smoothstep(0.03, 0.015, d) * step(0.0, sa));
    }
    vec3 col = vec3(0.1, 0.15, 0.2) + vec3(0.7, 0.6, 0.3) * spiral;
    fragColor = vec4(col, 1.0);
}
