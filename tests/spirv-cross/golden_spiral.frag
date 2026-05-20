#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fibonacci spiral (golden rectangle subdivision)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Golden spiral: r = a * phi^(2*theta/pi)
    float golden = 1.618;
    float spiral_r = 0.02 * pow(golden, a * 2.0 / 3.14159);
    float spiral_d = abs(r - spiral_r);
    float spiral = smoothstep(0.01, 0.005, spiral_d) * step(0.1, r) * step(r, 0.9);
    // Golden rectangles
    float rect = step(0.0, uv.x) * step(uv.x, 0.618) * step(0.0, uv.y) * step(uv.y, 1.0);
    rect += step(-0.618, uv.x) * step(uv.x, 0.0) * step(-1.0, uv.y) * step(uv.y, 0.0);
    vec3 col = vec3(0.1, 0.12, 0.15);
    col += vec3(0.85, 0.7, 0.3) * spiral;
    col += vec3(0.3, 0.4, 0.5) * rect * 0.3;
    fragColor = vec4(col, 1.0);
}
