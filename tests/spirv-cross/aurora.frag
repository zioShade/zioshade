#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Aurora borealis
    float a = uv.y * 3.0;
    float wave1 = sin(uv.x * 5.0 + a) * 0.5;
    float wave2 = sin(uv.x * 8.0 - a * 0.7 + 1.0) * 0.3;
    float wave3 = sin(uv.x * 3.0 + a * 1.5 + 2.0) * 0.2;
    float aurora = (wave1 + wave2 + wave3) * 0.5 + 0.5;
    // Vertical fade
    float fade = smoothstep(-0.3, 0.3, uv.y) * (1.0 - smoothstep(0.6, 1.0, uv.y));
    // Color bands: green at bottom, purple/blue at top
    vec3 green = vec3(0.1, 0.8, 0.3);
    vec3 purple = vec3(0.5, 0.2, 0.7);
    vec3 col = mix(green, purple, uv.y + 0.3) * aurora * fade;
    // Dark sky
    col += vec3(0.02, 0.02, 0.05);
    fragColor = vec4(col, 1.0);
}
