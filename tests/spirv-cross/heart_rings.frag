#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Concentric hearts
    float scale = 5.0;
    vec2 p = uv * scale;
    // Heart SDF
    vec2 q = vec2(abs(p.x), p.y);
    float d = length(q - vec2(0.25, 0.25)) - 0.25;
    d = min(d, length(q - vec2(0.0, 0.0)) - 0.25);
    d = max(d, -p.y);
    float heart = smoothstep(0.02, -0.02, d);
    // Rings within heart
    float rings = fract(length(p) * 3.0);
    float ring_line = smoothstep(0.04, 0.02, min(rings, 1.0 - rings));
    vec3 red = vec3(0.8, 0.15, 0.2);
    vec3 pink = vec3(1.0, 0.6, 0.7);
    vec3 col = vec3(0.05);
    col += mix(red, pink, ring_line) * heart;
    fragColor = vec4(col, 1.0);
}
