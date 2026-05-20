#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    // Electromagnetic wave
    float freq = 3.0;
    float amplitude = 0.5;
    float phase = uv.x * freq * 6.28;
    float e_field = sin(phase) * amplitude;
    float b_field = cos(phase) * amplitude;
    // Wave envelope
    float envelope = exp(-uv.x * 0.5);
    float e = e_field * envelope;
    float b = b_field * envelope;
    // Map to colors
    float e_y = 0.5 + e;
    float b_y = 0.5 + b * 0.5;
    vec3 col = vec3(0.0);
    if (abs(uv.y - e_y) < 0.02) col.r = 1.0;
    if (abs(uv.y - b_y) < 0.02) col.b = 1.0;
    col += vec3(0.1);
    fragColor = vec4(col, 1.0);
}
