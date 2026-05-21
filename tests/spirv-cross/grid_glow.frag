#version 310 es
precision highp float;
out vec4 fragColor;

// Test: nested for loop computing grid pattern
void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    vec3 col = vec3(0.0);
    for (int gy = 0; gy < 3; gy++) {
        for (int gx = 0; gx < 3; gx++) {
            vec2 center = vec2(float(gx), float(gy)) * 2.0 + 1.0;
            float d = length(uv - center);
            float brightness = 0.3 / (d + 0.1);
            vec3 tint = vec3(float(gx) * 0.3, float(gy) * 0.3, 0.5);
            col += tint * brightness;
        }
    }
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
