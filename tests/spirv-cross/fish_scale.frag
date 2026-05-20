#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Fish scale pattern
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Offset rows
    float offset = mod(cell.y, 2.0) * 0.5;
    float fx = fract(f.x + offset);
    // Arc shape (half circle)
    float d = length(vec2(fx - 0.5, f.y - 0.0));
    float arc = smoothstep(0.45, 0.42, d) * (1.0 - smoothstep(0.38, 0.35, d));
    // Color based on position
    vec3 teal = vec3(0.2, 0.6, 0.5);
    vec3 blue = vec3(0.15, 0.3, 0.6);
    vec3 shine = vec3(0.8, 0.9, 0.95);
    float bright = smoothstep(0.42, 0.38, length(vec2(fx - 0.35, f.y - 0.2)));
    vec3 col = mix(blue, teal, arc);
    col = mix(col, shine, bright * arc * 0.4);
    fragColor = vec4(col, 1.0);
}
