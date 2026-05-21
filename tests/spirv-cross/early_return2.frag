#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Test: multiple early returns from function
    float r = length(uv);
    vec3 col;
    if (r < 0.1) {
        col = vec3(1.0, 0.9, 0.7);
    } else {
        float d = r;
        for (int i = 1; i <= 5; i++) {
            float fi = float(i);
            float ring = abs(d - fi * 0.15);
            if (ring < 0.01) {
                col = vec3(0.3 + fi * 0.1, 0.5, 0.8 - fi * 0.1);
                fragColor = vec4(col, 1.0);
                return;
            }
        }
        col = vec3(0.02, 0.03, 0.05);
    }
    fragColor = vec4(col, 1.0);
}
