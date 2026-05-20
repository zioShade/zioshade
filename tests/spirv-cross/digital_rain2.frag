#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Digital rain (Matrix-style columns)
    float col_id = floor(uv.x);
    float col_phase = fract(sin(col_id * 127.1) * 43758.5);
    float speed = 1.0 + col_phase * 2.0;
    float y = fract(uv.y * 0.1 + col_phase - gl_FragCoord.x * 0.001 * speed);
    float brightness = smoothstep(0.0, 0.1, y) * (1.0 - smoothstep(0.3, 0.8, y));
    float head = smoothstep(0.02, 0.0, y) * 3.0;
    vec3 col = vec3(0.0, brightness * 0.8 + head, 0.0);
    col = min(col, vec3(1.0));
    fragColor = vec4(col, 1.0);
}
