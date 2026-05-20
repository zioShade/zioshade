#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Oil on water interference
    float thickness = sin(uv.x * 3.0 + sin(uv.y * 2.0)) * 0.5 + 0.5;
    thickness += 0.3 * sin(uv.x * 7.0 - uv.y * 5.0);
    thickness = thickness * 0.5 + 0.5;
    // Thin film interference for each wavelength
    float phase_r = thickness * 12.0;
    float phase_g = thickness * 15.0;
    float phase_b = thickness * 18.0;
    float r = cos(phase_r) * 0.5 + 0.5;
    float g = cos(phase_g) * 0.5 + 0.5;
    float b = cos(phase_b) * 0.5 + 0.5;
    vec3 col = vec3(r, g, b) * 0.8;
    col += vec3(0.1, 0.1, 0.15);
    fragColor = vec4(col, 1.0);
}
