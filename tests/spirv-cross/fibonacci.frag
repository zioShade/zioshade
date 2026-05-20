#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fibonacci spiral tiling
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Golden spiral
    float golden = 1.618;
    float spiral_r = 0.05 * pow(golden, a * 1.5);
    float spiral_d = abs(r - spiral_r);
    float spiral = smoothstep(0.015, 0.005, spiral_d) * step(0.1, r) * step(r, 0.85);
    // Fibonacci rectangles
    float rect1 = step(0.0, uv.x) * step(uv.x, 0.309) * step(-0.5, uv.y) * step(uv.y, 0.5);
    float rect2 = step(-0.5, uv.x) * step(uv.x, 0.0) * step(0.0, uv.y) * step(uv.y, 0.809);
    vec3 col = vec3(0.08, 0.1, 0.12);
    col += vec3(0.2, 0.3, 0.4) * (rect1 + rect2) * 0.3;
    col += vec3(0.85, 0.7, 0.3) * spiral;
    fragColor = vec4(col, 1.0);
}
