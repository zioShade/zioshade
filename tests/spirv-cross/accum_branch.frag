#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    // Accumulator in else-if branch
    vec3 col = vec3(0.05);
    if (r < 0.2) {
        col = vec3(1.0, 0.9, 0.7);
    } else if (r < 0.6) {
        float brightness = 0.5;
        brightness += 0.3 * (1.0 - r / 0.6);
        brightness *= sin(uv.x * 20.0) * 0.3 + 0.7;
        col = vec3(0.2, 0.5, 0.8) * brightness;
    } else {
        float fade = 1.0 - (r - 0.6) / 0.4;
        col = vec3(0.05, 0.1, 0.2) * fade;
    }
    fragColor = vec4(col, 1.0);
}
