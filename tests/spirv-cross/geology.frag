#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Geological cross-section
    float h = uv.y;
    // Rock layers with different colors
    vec3 soil = vec3(0.4, 0.3, 0.15);
    vec3 sandstone = vec3(0.8, 0.7, 0.5);
    vec3 limestone = vec3(0.7, 0.7, 0.6);
    vec3 shale = vec3(0.4, 0.4, 0.35);
    vec3 granite = vec3(0.6, 0.55, 0.5);
    vec3 col;
    if (h > 7.5) col = soil;
    else if (h > 6.0) col = sandstone;
    else if (h > 4.5) col = limestone;
    else if (h > 3.0) col = shale;
    else if (h > 1.5) col = sandstone;
    else col = granite;
    // Wavy layer boundaries
    float wave = sin(uv.x * 2.0) * 0.3;
    if (h > 7.5 + wave && h < 8.0 + wave) col = mix(soil, sandstone, fract(h));
    fragColor = vec4(col, 1.0);
}
