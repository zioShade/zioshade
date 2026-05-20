#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Interference of two point sources
    float d1 = length(uv - vec2(-0.3, 0.0));
    float d2 = length(uv - vec2(0.3, 0.0));
    float wave1 = sin(d1 * 40.0) * 0.5 + 0.5;
    float wave2 = sin(d2 * 40.0) * 0.5 + 0.5;
    float interference = (wave1 + wave2) * 0.5;
    vec3 col = vec3(interference * 0.8, interference * 0.5, interference);
    fragColor = vec4(col, 1.0);
}
