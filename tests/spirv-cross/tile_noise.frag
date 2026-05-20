#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Tileable noise texture
    float scale = 4.0;
    vec2 p = fract(uv * scale);
    vec2 id = floor(uv * scale);
    float n = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float n2 = fract(sin(dot(id + vec2(1, 0), vec2(127.1, 311.7))) * 43758.5);
    float n3 = fract(sin(dot(id + vec2(0, 1), vec2(127.1, 311.7))) * 43758.5);
    float n4 = fract(sin(dot(id + vec2(1, 1), vec2(127.1, 311.7))) * 43758.5);
    vec2 f = p * p * (3.0 - 2.0 * p);
    float val = mix(mix(n, n2, f.x), mix(n3, n4, f.x), f.y);
    vec3 col = vec3(val * 0.6, val * 0.5, val * 0.35);
    fragColor = vec4(col, 1.0);
}
