#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Windmill with rotating blades
    vec2 center = vec2(5.0, 6.0);
    vec2 p = uv - center;
    float r = length(p);
    float a = atan(p.y, p.x);
    // 4 blades
    float blade = 0.0;
    for (int i = 0; i < 4; i++) {
        float angle = float(i) * 1.5708;
        float da = mod(a - angle, 6.2832);
        da = min(da, 6.2832 - da);
        float blade_shape = smoothstep(0.15, 0.0, da) * smoothstep(0.05, 0.2, r) * smoothstep(2.5, 2.0, r);
        blade = max(blade, blade_shape);
    }
    // Tower
    float tower = smoothstep(0.1, 0.07, abs(p.x)) * step(-4.0, p.y) * step(p.y, 0.0);
    vec3 col = vec3(0.5, 0.7, 0.95); // sky
    col = mix(col, vec3(0.3, 0.5, 0.2), step(uv.y, 2.0)); // grass
    col = mix(col, vec3(0.9, 0.9, 0.9), blade);
    col = mix(col, vec3(0.6, 0.55, 0.5), tower);
    // Hub
    col = mix(col, vec3(0.4), smoothstep(0.15, 0.1, r));
    fragColor = vec4(col, 1.0);
}
