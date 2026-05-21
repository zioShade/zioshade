#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    vec3 col = vec3(0.0);
    float brightness = 1.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float ring = abs(r - (fi + 1.0) * 0.25);
        if (ring < 0.05) {
            brightness = 1.5 - fi * 0.3;
            col += vec3(0.3, 0.5, 0.7) * brightness;
        } else {
            brightness *= 0.8;
            col += vec3(0.02);
        }
    }
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
