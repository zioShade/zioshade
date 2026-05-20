#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Dragon scale pattern
    float scale = 3.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Offset every other row
    float offset = mod(cell.y, 2.0) * 0.5;
    float fx = fract(f.x + offset);
    // Scale shape: pointed top, rounded bottom
    float top = smoothstep(0.15, 0.1, fx * 0.5 + f.y * 0.8);
    float bot = smoothstep(0.12, 0.08, length(vec2(fx - 0.5, f.y - 0.3) * vec2(1.0, 1.5)));
    float scale_shape = max(top * step(f.y, 0.5), bot * step(0.5, f.y));
    vec3 iridescent = vec3(
        sin(uv.x * 3.0 + uv.y * 2.0) * 0.3 + 0.5,
        sin(uv.x * 2.0 - uv.y * 3.0 + 1.0) * 0.3 + 0.5,
        sin(uv.x * 4.0 + uv.y * 1.0 + 2.0) * 0.3 + 0.5
    );
    vec3 col = iridescent * (0.3 + 0.7 * scale_shape);
    fragColor = vec4(col, 1.0);
}
