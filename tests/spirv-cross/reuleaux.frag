#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Reuleaux triangle (constant-width shape)
    vec2 center = vec2(5.0, 5.0);
    float scale = 3.0;
    vec2 p = (uv - center) / scale;
    // Three circles
    float angle = 3.14159 / 3.0;
    vec2 c1 = vec2(0.0, 0.577);
    vec2 c2 = vec2(-0.5, -0.289);
    vec2 c3 = vec2(0.5, -0.289);
    float d1 = length(p - c1);
    float d2 = length(p - c2);
    float d3 = length(p - c3);
    float reuleaux = 1.0 - step(1.0, d1) * step(1.0, d2) * step(1.0, d3);
    vec3 col = vec3(0.3, 0.5, 0.8) * reuleaux;
    fragColor = vec4(col, 1.0);
}
