#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Box blur approximation (offset samples)
    float dx = 2.0 / 300.0;
    float dy = 2.0 / 300.0;
    float sum = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 offset_uv = uv + vec2(float(x) * dx, float(y) * dy);
            sum += step(length(offset_uv), 0.5);
        }
    }
    float blurred = sum / 9.0;
    fragColor = vec4(vec3(blurred), 1.0);
}
