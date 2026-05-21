#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float min_d = 10.0;
    int closest = 0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        vec2 center = vec2(sin(fi * 0.785) * 0.7, cos(fi * 0.785) * 0.7);
        float d = length(uv - center);
        if (d < min_d) {
            min_d = d;
            closest = i;
        }
        if (d < 0.05) break;
    }
    vec3 col = vec3(float(closest) / 8.0, min_d, 0.5);
    fragColor = vec4(col, 1.0);
}
