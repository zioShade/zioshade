#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Galton board / bean machine (histogram)
    float bins = 10.0;
    float bin_id = floor((uv.x + 1.0) * bins / 2.0);
    float bin_f = fract((uv.x + 1.0) * bins / 2.0);
    // Gaussian-like distribution
    float center = bins / 2.0;
    float sigma = bins / 4.0;
    float height = exp(-((bin_id - center) * (bin_id - center)) / (2.0 * sigma * sigma));
    height *= 0.8;
    float bar = smoothstep(0.04, 0.0, min(bin_f, 1.0 - bin_f)) * step(uv.y + 0.8, height - 0.8) * step(-0.8, uv.y);
    // Gaussian curve overlay
    float curve_y = height - 0.8;
    float curve = smoothstep(0.01, 0.005, abs(uv.y - curve_y));
    vec3 col = vec3(0.1) + vec3(0.2, 0.5, 0.8) * bar + vec3(1.0, 0.5, 0.1) * curve * 0.5;
    fragColor = vec4(col, 1.0);
}
