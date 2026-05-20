#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Tangram puzzle pieces
    vec3 col = vec3(0.95, 0.93, 0.88);
    // Large triangle 1
    float t1 = step(0.0, uv.y) * step(uv.y, -uv.x + 0.8) * step(0.0, uv.x);
    // Large triangle 2
    float t2 = step(uv.y, 0.0) * step(-0.8, uv.y - uv.x) * step(uv.x, 0.0);
    // Medium triangle
    float t3 = step(0.0, uv.x) * step(uv.x, 0.4) * step(-0.4, uv.y) * step(uv.y, 0.0);
    // Square
    float sq = step(0.0, uv.x) * step(uv.x, 0.4) * step(0.0, uv.y) * step(uv.y, 0.4) * (1.0 - t1);
    col = mix(col, vec3(0.9, 0.3, 0.2), t1);
    col = mix(col, vec3(0.2, 0.6, 0.9), t2);
    col = mix(col, vec3(0.9, 0.8, 0.1), t3);
    col = mix(col, vec3(0.4, 0.8, 0.3), sq);
    fragColor = vec4(col, 1.0);
}
