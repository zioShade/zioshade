#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sound wave / oscilloscope
    float t = uv.x * 6.28 * 3.0;
    float wave1 = sin(t) * 0.3;
    float wave2 = sin(t * 2.0 + 1.0) * 0.15;
    float wave3 = sin(t * 0.5 - 0.5) * 0.1;
    float combined = wave1 + wave2 + wave3;
    float line = smoothstep(0.01, 0.005, abs(uv.y - combined));
    // Glow
    float glow = smoothstep(0.05, 0.0, abs(uv.y - combined)) * 0.3;
    vec3 col = vec3(0.0, line + glow, line * 0.5);
    col += vec3(0.0, 0.0, 0.05);
    fragColor = vec4(col, 1.0);
}
