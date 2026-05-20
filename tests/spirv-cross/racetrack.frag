#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Race track / speedway
    vec3 col = vec3(0.3, 0.5, 0.2); // grass
    // Oval track
    vec2 center = vec2(5.0, 5.0);
    float dx = (uv.x - center.x) / 3.0;
    float dy = (uv.y - center.y) / 2.0;
    float d = sqrt(dx * dx + dy * dy);
    float track = smoothstep(1.2, 1.15, d) * (1.0 - smoothstep(0.7, 0.75, d));
    vec3 asphalt = vec3(0.25, 0.25, 0.25);
    col = mix(col, asphalt, track);
    // Center line (dashed)
    float center_line = smoothstep(0.02, 0.01, abs(d - 0.95));
    float dash = step(0.5, fract(atan(dy, dx) * 5.0));
    col += vec3(1.0) * center_line * dash * 0.5;
    // Start/finish line
    col += vec3(1.0) * smoothstep(0.02, 0.01, abs(uv.x - 2.0)) * track;
    fragColor = vec4(col, 1.0);
}
