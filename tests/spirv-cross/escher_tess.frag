#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // M.C. Escher sky and water tessellation
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Upward pointing triangles (birds/sky)
    float tri_up = f.x + f.y;
    float tri_down = (1.0 - f.x) + f.y;
    float shape = mod(cell.x + cell.y, 2.0) > 0.5 ? tri_up : tri_down;
    float outline = smoothstep(0.02, 0.01, abs(shape - 1.0));
    vec3 sky = vec3(0.3, 0.5, 0.8);
    vec3 water = vec3(0.1, 0.2, 0.4);
    vec3 line = vec3(0.0);
    vec3 col = shape > 1.0 ? sky : water;
    col = mix(col, line, outline * 0.8);
    fragColor = vec4(col, 1.0);
}
