#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Butterfly wing pattern with eyespots
    uv.x = abs(uv.x); // bilateral symmetry
    float r = length(uv - vec2(4.0, 5.0));
    float a = atan(uv.y - 5.0, uv.x - 4.0);
    // Wing shape (oval)
    float wing = smoothstep(4.5, 4.3, r * (1.0 + 0.3 * cos(a * 2.0)));
    // Eyespot
    float spot_r = length(uv - vec2(5.5, 5.5));
    float spot_outer = smoothstep(1.2, 1.1, spot_r) * (1.0 - smoothstep(0.8, 0.7, spot_r));
    float spot_inner = smoothstep(0.4, 0.3, spot_r);
    // Pattern veins
    float veins = smoothstep(0.02, 0.01, abs(sin(a * 8.0 + r * 3.0)));
    vec3 orange = vec3(0.9, 0.6, 0.1);
    vec3 black = vec3(0.05);
    vec3 blue = vec3(0.1, 0.3, 0.8);
    vec3 col = vec3(0.05);
    col = mix(col, orange, wing);
    col = mix(col, black, spot_outer * wing);
    col = mix(col, blue, spot_inner * wing);
    col = mix(col, black * 0.8, veins * wing * 0.3);
    fragColor = vec4(col, 1.0);
}
