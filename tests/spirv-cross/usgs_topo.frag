#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // USGS topographic contour map
    float h = 0.0;
    h += sin(uv.x * 0.4 + 1.0) * cos(uv.y * 0.6) * 0.4;
    h += cos(uv.x * 0.8 - uv.y * 0.3 + 2.0) * 0.3;
    h += sin(uv.x * 1.2 + uv.y * 0.9 - 1.0) * 0.2;
    h += cos(uv.y * 1.5 + uv.x * 0.2) * 0.15;
    h = h * 0.5 + 0.5;
    // Contour lines with varying weight
    float contour_val = fract(h * 15.0);
    float line_w = 0.04;
    float thick_line = smoothstep(line_w, line_w * 0.5, min(contour_val, 1.0 - contour_val));
    // Major contour every 5 lines
    float major_val = fract(h * 3.0);
    float major_line = smoothstep(0.05, 0.02, min(major_val, 1.0 - major_val));
    // Green-brown elevation coloring
    vec3 low = vec3(0.2, 0.5, 0.2);
    vec3 mid = vec3(0.7, 0.6, 0.3);
    vec3 high = vec3(0.9, 0.85, 0.8);
    vec3 col = h < 0.4 ? mix(low, mid, h / 0.4) : mix(mid, high, (h - 0.4) / 0.6);
    col = mix(col, vec3(0.15), thick_line * 0.4);
    col = mix(col, vec3(0.1), major_line * 0.6);
    fragColor = vec4(col, 1.0);
}
