#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art (Bridget Riley style)
    float scale = 12.0;
    float dist = length(uv);
    // Wavy vertical lines
    float wave = sin(uv.y * 20.0 + dist * 10.0) * 0.1;
    float lines = sin((uv.x + wave) * scale * 3.14) * 0.5 + 0.5;
    // Monochrome
    vec3 col = vec3(lines);
    // Vignette
    col *= 1.0 - dist * 0.5;
    fragColor = vec4(col, 1.0);
}
