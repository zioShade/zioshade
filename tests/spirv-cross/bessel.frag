#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Bessel function pattern (ripple from circular aperture)
    float r = length(uv);
    // Approximate J0(r) pattern
    float j0 = cos(r * 15.0 - 0.78) / (r * 3.0 + 1.0);
    float pattern = j0 * j0;
    // Airy disk: bright center with rings
    vec3 col = vec3(0.0);
    col += vec3(0.3, 0.5, 0.9) * pattern;
    col += vec3(0.5, 0.7, 1.0) * exp(-r * r * 20.0);
    col *= smoothstep(1.2, 0.5, r);
    fragColor = vec4(col, 1.0);
}
