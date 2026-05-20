#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Woven basket pattern
    vec2 grid = fract(uv * 4.0);
    float h_strip = smoothstep(0.48, 0.5, grid.x) * (1.0 - smoothstep(0.5, 0.52, grid.x));
    float v_strip = smoothstep(0.48, 0.5, grid.y) * (1.0 - smoothstep(0.5, 0.52, grid.y));
    // Over-under weaving
    vec2 id = floor(uv * 4.0);
    float checker = mod(id.x + id.y, 2.0);
    float h_visible = h_strip * mix(1.0, 0.3, v_strip * checker);
    float v_visible = v_strip * mix(0.3, 1.0, h_strip * checker);
    float weave = max(h_visible, v_visible);
    vec3 col = mix(vec3(0.6, 0.45, 0.2), vec3(0.8, 0.65, 0.35), weave);
    fragColor = vec4(col, 1.0);
}
