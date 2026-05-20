#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Topographic height map with contour lines
    float h = 0.0;
    h += sin(uv.x * 1.5) * cos(uv.y * 2.0) * 0.5;
    h += sin(uv.x * 0.7 + 1.0) * cos(uv.y * 1.3 + 0.5) * 0.3;
    h += cos(uv.x * 2.5 - uv.y * 1.8) * 0.2;
    h = h * 0.5 + 0.5;
    // Contour lines
    float contour = fract(h * 10.0);
    float line = smoothstep(0.05, 0.02, min(contour, 1.0 - contour));
    // Color by elevation
    vec3 low = vec3(0.1, 0.3, 0.1);
    vec3 mid = vec3(0.6, 0.5, 0.2);
    vec3 high = vec3(0.9, 0.85, 0.8);
    vec3 col = h < 0.4 ? mix(low, mid, h / 0.4) : mix(mid, high, (h - 0.4) / 0.6);
    col = mix(col, vec3(0.1), line * 0.7);
    fragColor = vec4(col, 1.0);
}
