#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Gravity well / black hole
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Accretion disk
    float disk_r = 0.4 + 0.05 * sin(a * 6.0);
    float disk = smoothstep(disk_r + 0.15, disk_r, r) * (1.0 - smoothstep(disk_r - 0.15, disk_r - 0.05, r));
    // Event horizon
    float horizon = smoothstep(0.12, 0.08, r);
    // Lensing effect on stars
    float lensed_r = r + 0.1 / (r + 0.1);
    float star = fract(sin(dot(floor(vec2(cos(a), sin(a)) * lensed_r * 50.0), vec2(127.1, 311.7))) * 43758.5);
    vec3 col = vec3(0.0);
    col += vec3(0.9, 0.6, 0.2) * disk * 2.0;
    col += vec3(1.0, 0.3, 0.05) * disk * smoothstep(0.3, 0.15, r);
    col = mix(col, vec3(0.0), horizon);
    col += vec3(1.0) * step(0.98, star) * 0.3;
    fragColor = vec4(col, 1.0);
}
