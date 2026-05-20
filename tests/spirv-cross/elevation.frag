#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Topographic elevation bands with contour lines
    float h = 0.0;
    h += sin(uv.x * 0.4 + 0.5) * cos(uv.y * 0.6) * 0.5;
    h += cos(uv.x * 0.8 + uv.y * 0.3 - 1.0) * 0.3;
    h += sin(uv.x * 1.2 - uv.y * 0.7 + 2.0) * 0.15;
    h = h * 0.5 + 0.5;
    // Discrete elevation bands
    float band = floor(h * 10.0);
    float band_f = fract(h * 10.0);
    // Each band has a color
    vec3 col;
    if (band < 2.0) col = vec3(0.1, 0.3, 0.6);
    else if (band < 4.0) col = vec3(0.2, 0.6, 0.2);
    else if (band < 6.0) col = vec3(0.7, 0.6, 0.3);
    else if (band < 8.0) col = vec3(0.5, 0.35, 0.2);
    else col = vec3(0.95, 0.95, 0.95);
    // Contour line at each band boundary
    float line = smoothstep(0.05, 0.02, band_f) * 0.3;
    col = mix(col, vec3(0.1), line);
    fragColor = vec4(col, 1.0);
}
