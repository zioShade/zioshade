#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Topographic terrain with contour lines
    float h = 0.0;
    h += sin(uv.x * 0.7) * cos(uv.y * 0.9) * 0.5;
    h += cos(uv.x * 1.3 - uv.y * 0.8) * 0.3;
    h += sin(uv.x * 2.1 + uv.y * 1.7) * 0.2;
    h = h * 0.5 + 0.5;
    // Contour lines
    float contour = fract(h * 12.0);
    float line = smoothstep(0.04, 0.01, min(contour, 1.0 - contour));
    // Elevation coloring
    vec3 low = vec3(0.1, 0.4, 0.1);
    vec3 mid = vec3(0.6, 0.5, 0.2);
    vec3 high = vec3(0.95, 0.95, 0.95);
    vec3 col = h < 0.35 ? mix(low, mid, h / 0.35) : mix(mid, high, (h - 0.35) / 0.65);
    col = mix(col, vec3(0.1), line * 0.6);
    fragColor = vec4(col, 1.0);
}
