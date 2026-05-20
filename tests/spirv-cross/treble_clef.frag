#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Treble clef approximation
    float r = length(uv);
    float a = atan(uv.y - 0.1, uv.x);
    // Spiral body
    float spiral_r = 0.2 + 0.15 * sin(a * 1.5);
    float body = smoothstep(spiral_r + 0.03, spiral_r - 0.03, r) * step(0.0, uv.y - 0.1);
    // Vertical stem
    float stem = smoothstep(0.02, 0.01, abs(uv.x + 0.05)) * step(-0.6, uv.y) * step(uv.y, 0.8);
    vec3 col = vec3(0.05) + vec3(0.05) * body;
    col += vec3(0.1) * stem;
    fragColor = vec4(col, 1.0);
}
