#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Doppler effect visualization
    float source_x = 5.0 + sin(uv.y * 0.5) * 2.0;
    float dx = uv.x - source_x;
    float d = abs(dx);
    // Compressed waves ahead, stretched behind
    float freq = dx > 0.0 ? 15.0 : 8.0;
    float amplitude = 1.0 / (d + 0.5);
    float wave = sin(d * freq) * amplitude;
    float line = smoothstep(0.03, 0.01, abs(wave));
    // Source marker
    float marker = smoothstep(0.1, 0.08, length(uv - vec2(source_x, uv.y)));
    vec3 col = vec3(0.05);
    col += vec3(0.3, 0.6, 1.0) * line;
    col += vec3(1.0, 0.3, 0.1) * marker;
    fragColor = vec4(col, 1.0);
}
