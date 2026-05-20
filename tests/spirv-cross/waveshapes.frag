#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Waveshape visualization (sine, square, triangle, sawtooth)
    float x = uv.x * 6.28 * 2.0;
    // Select waveform based on horizontal position
    int quadrant = int(floor(uv.x * 2.0 + 1.0));
    float wave = 0.0;
    switch (quadrant) {
        case 0: wave = sin(x); break;
        case 1: wave = step(0.0, sin(x)) * 2.0 - 1.0; break;
        case 2: wave = 2.0 * abs(2.0 * fract(x / 6.28) - 1.0) - 1.0; break;
        case 3: wave = fract(x / 6.28) * 2.0 - 1.0; break;
        default: wave = 0.0; break;
    }
    float d = abs(uv.y - wave * 0.3);
    float line = smoothstep(0.01, 0.005, d);
    // Axis
    float axis = smoothstep(0.005, 0.002, abs(uv.y));
    // Separator
    float sep = smoothstep(0.005, 0.002, abs(fract(uv.x * 2.0 + 0.5) - 0.5));
    vec3 col = vec3(0.05) + vec3(0.3, 0.8, 0.3) * line + vec3(0.2) * axis + vec3(0.1) * sep;
    fragColor = vec4(col, 1.0);
}
