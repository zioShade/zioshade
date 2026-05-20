#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Woven carpet pattern
    float scale = 6.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Offset every other row
    float offset = mod(cell.y, 2.0) * 0.5;
    float fx = fract(f.x + offset);
    // Vertical vs horizontal thread dominance
    float checker = mod(cell.x + cell.y, 2.0);
    float h_thread = checker > 0.5 ? f.y : 1.0 - f.y;
    float v_thread = checker > 0.5 ? fx : 1.0 - fx;
    float weave = sin(h_thread * 20.0) * sin(v_thread * 20.0);
    weave = weave * 0.3 + 0.7;
    // Color variation
    float n = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    vec3 red = vec3(0.7, 0.15, 0.1);
    vec3 blue = vec3(0.1, 0.15, 0.6);
    vec3 col = (n < 0.5 ? red : blue) * weave;
    fragColor = vec4(col, 1.0);
}
