#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Honeycomb (hex grid fill)
    float scale = 8.0;
    vec2 p = uv * scale;
    // Hex grid coordinates
    vec2 r = vec2(1.0, 1.732);
    vec2 h = vec2(r.x * 0.5, r.y);
    vec2 a_val = mod(p, r) - h * 0.5;
    vec2 b_val = mod(p + h * 0.5, r) - h * 0.5;
    float d = min(length(a_val), length(b_val));
    float hex = smoothstep(0.5, 0.45, d);
    float h2 = fract(sin(dot(floor(p / r + 0.5), vec2(127.1, 311.7))) * 43758.5);
    vec3 col = vec3(0.8, 0.65, 0.1) * hex * (0.7 + 0.3 * h2);
    col += vec3(0.1) * (1.0 - hex);
    fragColor = vec4(col, 1.0);
}
