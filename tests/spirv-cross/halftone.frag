#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Halftone print effect (dots varying in size)
    float scale = 12.0;
    vec2 cell = floor(uv * scale);
    vec2 f = fract(uv * scale) - 0.5;
    // Tone value from underlying pattern
    float tone = sin(cell.x * 0.5 + cell.y * 0.7) * 0.5 + 0.5;
    float dot_size = tone * 0.4;
    float d = length(f);
    float dot = smoothstep(dot_size + 0.02, dot_size - 0.02, d);
    vec3 ink = vec3(0.1);
    vec3 paper = vec3(0.95);
    vec3 col = mix(paper, ink, dot);
    fragColor = vec4(col, 1.0);
}
