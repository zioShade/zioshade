#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Art Deco sunburst v2
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float rays = sin(a * 12.0) * 0.5 + 0.5;
    rays = step(0.5, rays);
    float frame_top = smoothstep(0.01, 0.005, abs(uv.y - 0.8)) * step(abs(uv.x), 0.7);
    float frame_side_l = smoothstep(0.01, 0.005, abs(uv.x + 0.7)) * step(-0.8, uv.y);
    float frame_side_r = smoothstep(0.01, 0.005, abs(uv.x - 0.7)) * step(-0.8, uv.y);
    float frame = max(max(frame_top, frame_side_l), frame_side_r);
    vec3 gold = vec3(0.85, 0.7, 0.25);
    vec3 dark = vec3(0.1, 0.08, 0.05);
    vec3 col = dark;
    float sun = smoothstep(0.6, 0.0, r) * rays;
    col = mix(col, gold * 0.5, sun * 0.6);
    col += gold * frame;
    col += vec3(0.95, 0.8, 0.3) * smoothstep(0.15, 0.1, r);
    fragColor = vec4(col, 1.0);
}
