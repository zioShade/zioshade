#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Parallax starfield layers
    float t = gl_FragCoord.x * 0.003;
    vec3 col = vec3(0.02, 0.02, 0.05);
    // Far stars
    for (int i = 0; i < 3; i++) {
        vec2 offset = vec2(float(i) * 0.3, float(i) * 0.1);
        vec2 star_uv = uv * (2.0 + float(i)) + offset;
        vec2 star_id = floor(star_uv * 10.0);
        float brightness = fract(sin(dot(star_id, vec2(127.1, 311.7))) * 43758.5453);
        vec2 star_pos = fract(star_uv * 10.0);
        float d = length(star_pos - 0.5);
        float star = smoothstep(0.1, 0.0, d) * brightness;
        col += vec3(star) * (0.3 + 0.2 * float(i));
    }
    fragColor = vec4(col, 1.0);
}
