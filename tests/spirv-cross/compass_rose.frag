#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Compass rose
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    // 8-pointed star
    float star_a = abs(mod(a + 0.3927, 0.7854) - 0.3927);
    float star_r = 0.3 + 0.3 * cos(star_a * 4.0);
    float star = smoothstep(star_r + 0.01, star_r - 0.01, r);
    // Cardinal direction emphasis
    float cardinal = smoothstep(0.02, 0.0, abs(mod(a, 1.5708) - 0.7854) - 0.75);
    vec3 col = vec3(0.95, 0.9, 0.8) * star;
    col = mix(col, vec3(0.8, 0.1, 0.1), cardinal * star * 0.5);
    col += vec3(0.1) * (1.0 - star);
    fragColor = vec4(col, 1.0);
}
