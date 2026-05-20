#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Möbius strip approximation
    float t = uv.x * 6.28;
    float s = uv.y * 2.0 - 1.0;
    float half_t = t * 0.5;
    // Surface parameterization
    float x_pos = (1.0 + s * 0.3 * cos(half_t)) * cos(t);
    float y_pos = (1.0 + s * 0.3 * cos(half_t)) * sin(t);
    float z_pos = s * 0.3 * sin(half_t);
    // Simple shading based on surface normal approximation
    float shade = 0.5 + 0.5 * z_pos;
    vec3 col = vec3(0.3, 0.5, 0.8) * shade;
    // Edge highlight
    float edge = smoothstep(0.9, 1.0, abs(uv.y * 2.0 - 1.0));
    col += vec3(0.3) * edge;
    fragColor = vec4(col, 1.0);
}
