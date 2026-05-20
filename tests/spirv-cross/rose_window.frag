#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Rose window (gothic cathedral)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Outer ring
    float ring = smoothstep(0.85, 0.83, r) * (1.0 - smoothstep(0.8, 0.78, r));
    // Inner petals
    float petals = 8.0;
    float petal_a = mod(a, 6.2832 / petals);
    petal_a = abs(petal_a - 3.1416 / petals);
    float petal = smoothstep(0.15, 0.1, petal_a * r) * step(0.15, r) * step(r, 0.75);
    // Center rosette
    float center = smoothstep(0.15, 0.13, r) * (1.0 - smoothstep(0.1, 0.08, r));
    // Color
    vec3 glass_red = vec3(0.8, 0.2, 0.15);
    vec3 glass_blue = vec3(0.15, 0.2, 0.7);
    vec3 glass_gold = vec3(0.85, 0.7, 0.2);
    vec3 stone = vec3(0.6, 0.58, 0.55);
    vec3 col = stone;
    col = mix(col, glass_red, petal);
    col = mix(col, glass_blue, center);
    col = mix(col, glass_gold, ring);
    fragColor = vec4(col, 1.0);
}
