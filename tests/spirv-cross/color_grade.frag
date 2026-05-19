#version 450

// Test: nested ternary for color grading
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float luminance = (uv.x + uv.y) * 0.5;

    // Color grading: shadows, midtones, highlights
    vec3 col = luminance < 0.33
        ? vec3(0.1, 0.05, 0.2) * luminance * 3.0
        : luminance < 0.66
            ? vec3(0.8, 0.6, 0.3) * (luminance - 0.33) * 3.0
            : vec3(1.0, 0.95, 0.8) * (luminance - 0.66) * 3.0;

    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
