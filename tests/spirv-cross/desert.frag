#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // Desert dune with sand texture
    float dune1 = sin(uv.x * 0.3 + sin(uv.y * 0.2) * 2.0) * 1.5;
    float dune2 = sin(uv.x * 0.5 + uv.y * 0.1 + 1.0) * 1.0;
    float height = dune1 + dune2 + 5.0;
    float above = step(height, uv.y);
    // Sand gradient
    vec3 sand_light = vec3(0.95, 0.85, 0.65);
    vec3 sand_dark = vec3(0.75, 0.6, 0.4);
    float shade = sin(uv.y * 10.0 + uv.x * 3.0) * 0.1 + 0.5;
    vec3 sky = mix(vec3(0.6, 0.75, 0.9), vec3(0.2, 0.4, 0.7), uv.y / 15.0);
    vec3 sand = mix(sand_dark, sand_light, shade);
    vec3 col = above > 0.5 ? sky : sand;
    fragColor = vec4(col, 1.0);
}
