#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Bezold effect (optical illusion - same gray looks different)
    float gray = 0.5;
    // Horizontal red stripes top, blue stripes bottom
    float stripe_top = step(0.5, fract(uv.y * 30.0)) * step(0.0, uv.y);
    float stripe_bot = step(0.5, fract(uv.y * 30.0)) * step(uv.y, 0.0);
    vec3 red = vec3(0.9, 0.1, 0.1);
    vec3 blue = vec3(0.1, 0.1, 0.9);
    vec3 gray_col = vec3(gray);
    vec3 col = vec3(0.0);
    if (uv.y > 0.0) {
        col = mix(gray_col, red, stripe_top * 0.5);
    } else {
        col = mix(gray_col, blue, stripe_bot * 0.5);
    }
    fragColor = vec4(col, 1.0);
}
