#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Marble texture
    float turbulence = 0.0;
    float freq = 1.0;
    float amp = 1.0;
    for (int i = 0; i < 4; i++) {
        turbulence += sin(uv.x * freq + sin(uv.y * freq * 0.7 + i * 1.3) * amp) * amp;
        freq *= 2.0;
        amp *= 0.5;
    }
    float marble = sin(uv.x * 3.0 + turbulence * 2.0) * 0.5 + 0.5;
    vec3 white = vec3(0.95, 0.93, 0.9);
    vec3 gray = vec3(0.6, 0.58, 0.55);
    vec3 vein = vec3(0.3, 0.28, 0.25);
    vec3 col = mix(white, gray, marble);
    col = mix(col, vein, smoothstep(0.45, 0.5, marble) * 0.5);
    fragColor = vec4(col, 1.0);
}
