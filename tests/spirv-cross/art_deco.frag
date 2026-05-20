#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Art deco sunburst
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    // Alternating rays
    float rays = step(0.0, sin(a * 12.0));
    // Fan shape
    float fan = step(r, 0.7) * step(0.0, uv.y);
    // Geometric border
    float border = smoothstep(0.7, 0.68, r) * (1.0 - smoothstep(0.65, 0.63, r));
    vec3 gold = vec3(0.85, 0.7, 0.25);
    vec3 teal = vec3(0.1, 0.35, 0.35);
    vec3 col = mix(teal, gold, rays * fan);
    col += vec3(0.9, 0.8, 0.6) * border * step(uv.y, 0.0);
    fragColor = vec4(col, 1.0);
}
