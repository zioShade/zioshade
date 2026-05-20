#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // US flag approximation
    float stripe = step(0.5, fract(uv.y * 13.0 / 7.0));
    vec3 red = vec3(0.7, 0.1, 0.1);
    vec3 white = vec3(0.95);
    vec3 blue = vec3(0.1, 0.1, 0.5);
    vec3 col = mix(red, white, stripe);
    // Blue canton
    if (uv.x < 3.0 && uv.y > 3.5) {
        col = blue;
        // Stars (simplified as dots)
        vec2 star_uv = (vec2(uv.x, uv.y - 3.5)) * vec2(8.0, 10.0);
        vec2 star_cell = floor(star_uv);
        vec2 star_f = fract(star_uv);
        float is_star = fract(sin(dot(star_cell, vec2(127.1, 311.7))) * 43758.5);
        if (is_star > 0.5 && length(star_f - 0.5) < 0.2) {
            col = white;
        }
    }
    fragColor = vec4(col, 1.0);
}
