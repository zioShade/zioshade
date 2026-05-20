#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Escher-style impossible staircase
    float scale = 3.0;
    vec2 p = uv * scale;
    // Stairs going around in a square
    float stairs = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float side = mod(fi, 4.0);
        float x_off = step(0.0, side - 0.5) * step(side, 1.5);
        float y_off = step(1.5, side) * step(side, 2.5);
        vec2 sp = vec2(p.x - x_off * 2.0, p.y - y_off * 2.0);
        float step_num = floor(sp.x * 3.0) * 0.1;
        float step_d = abs(sp.y - step_num);
        stairs += smoothstep(0.1, 0.05, step_d) * step(0.0, sp.x) * step(sp.x, 1.0);
    }
    vec3 col = vec3(0.1) + vec3(0.7, 0.6, 0.4) * stairs;
    fragColor = vec4(col, 1.0);
}
