#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Geometric quilt pattern
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // Diamond in each cell
    float d = abs(f.x - 0.5) + abs(f.y - 0.5);
    float diamond = smoothstep(0.35, 0.3, d);
    float inner = smoothstep(0.2, 0.15, d);
    // Alternate warm/cool
    float checker = mod(cell.x + cell.y, 2.0);
    vec3 warm1 = vec3(0.8, 0.3, 0.2);
    vec3 warm2 = vec3(0.9, 0.7, 0.2);
    vec3 cool1 = vec3(0.2, 0.3, 0.7);
    vec3 cool2 = vec3(0.2, 0.7, 0.5);
    vec3 bg = checker > 0.5 ? cool1 : warm1;
    vec3 fg = checker > 0.5 ? warm2 : cool2;
    vec3 col = mix(bg, fg, diamond);
    col = mix(col, vec3(1.0), inner * 0.3);
    fragColor = vec4(col, 1.0);
}
