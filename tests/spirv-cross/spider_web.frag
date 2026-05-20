#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spider web (radial + spiral)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Radial threads
    float spokes = 12.0;
    float spoke_angle = 6.28 / spokes;
    float spoke_dist = mod(a, spoke_angle);
    spoke_dist = min(spoke_dist, spoke_angle - spoke_dist);
    float spoke = smoothstep(0.02, 0.01, spoke_dist * r);
    // Spiral thread
    float spiral_r = fract(r * 5.0 - a / 6.28);
    float spiral = smoothstep(0.05, 0.03, min(spiral_r, 1.0 - spiral_r));
    float web = max(spoke, spiral) * smoothstep(0.05, 0.15, r) * (1.0 - smoothstep(0.9, 1.0, r));
    // Dew drops
    float dew1 = smoothstep(0.03, 0.02, length(uv - vec2(0.3, 0.2)));
    float dew2 = smoothstep(0.02, 0.01, length(uv - vec2(-0.1, 0.4)));
    vec3 col = vec3(0.1) + vec3(0.7, 0.75, 0.8) * web;
    col += vec3(0.5, 0.7, 1.0) * (dew1 + dew2);
    fragColor = vec4(col, 1.0);
}
