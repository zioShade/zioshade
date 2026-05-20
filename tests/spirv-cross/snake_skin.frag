#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Snake skin pattern
    float scale = 5.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Hex offset rows
    float offset = mod(cell.y, 2.0) * 0.5;
    float fx = f.x + offset;
    if (fx > 1.0) fx -= 1.0;
    // Diamond scale pattern
    float d1 = abs(fx - 0.5);
    float d2 = abs(f.y - 0.5);
    float diamond = d1 + d2;
    float outline = smoothstep(0.02, 0.01, abs(diamond - 0.4));
    float center = smoothstep(0.3, 0.1, diamond);
    vec3 base = vec3(0.3, 0.4, 0.15);
    vec3 highlight = vec3(0.5, 0.55, 0.2);
    vec3 dark = vec3(0.15, 0.2, 0.08);
    vec3 col = mix(base, highlight, center);
    col = mix(col, dark, outline);
    fragColor = vec4(col, 1.0);
}
