#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Shield / crest pattern
    float r = length(uv);
    // Shield shape (circle top + pointed bottom)
    float shield = 1.0;
    if (uv.y > 0.0) {
        shield *= step(r, 0.8);
    } else {
        float w = 0.8 + uv.y * 0.5;
        shield *= step(abs(uv.x), w);
        shield *= step(uv.y, -0.2);
    }
    // Diagonal quarters
    float quarter = step(0.0, uv.x) * step(0.0, uv.y) + step(uv.x, 0.0) * step(uv.y, 0.0);
    vec3 gold = vec3(0.85, 0.7, 0.2);
    vec3 blue = vec3(0.1, 0.15, 0.5);
    vec3 col = mix(blue, gold, quarter) * shield;
    // Cross
    float cross_h = smoothstep(0.05, 0.03, abs(uv.y)) * shield;
    float cross_v = smoothstep(0.05, 0.03, abs(uv.x)) * shield;
    col = mix(col, vec3(0.9, 0.9, 0.95), max(cross_h, cross_v));
    fragColor = vec4(col, 1.0);
}
