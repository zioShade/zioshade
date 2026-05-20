#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Art deco geometric border
    float scale = 2.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Zigzag border
    float zig = abs(f.x - step(0.5, fract(cell.y * 0.5)) * 0.5 - 0.25);
    float border = smoothstep(0.06, 0.04, zig);
    // Fan pattern between zigzags
    float fan_a = atan(f.y - 0.5, f.x - 0.5);
    float fan_r = length(vec2(f.x - 0.5, f.y - 0.5));
    float fan = smoothstep(0.3, 0.28, fan_r) * step(0.0, cos(fan_a * 4.0));
    vec3 gold = vec3(0.85, 0.7, 0.25);
    vec3 teal = vec3(0.05, 0.3, 0.35);
    vec3 cream = vec3(0.95, 0.92, 0.85);
    vec3 col = cream;
    col = mix(col, teal, border);
    col = mix(col, gold, fan);
    fragColor = vec4(col, 1.0);
}
