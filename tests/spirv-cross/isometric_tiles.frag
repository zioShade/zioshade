#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    // Isometric tile map
    vec2 iso = vec2(uv.x - uv.y, (uv.x + uv.y) * 0.5);
    vec2 tile = floor(iso);
    float h = fract(sin(dot(tile, vec2(127.1, 311.7))) * 43758.5453);
    vec3 col = mix(vec3(0.3, 0.5, 0.3), vec3(0.6, 0.4, 0.2), h);
    // Grid lines
    vec2 f = fract(iso);
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    col *= 0.7 + 0.3 * smoothstep(0.0, 0.05, edge);
    fragColor = vec4(col, 1.0);
}
