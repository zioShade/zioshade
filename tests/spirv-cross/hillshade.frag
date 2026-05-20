#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Relief map with hillshading
    float h = 0.0;
    h += sin(uv.x * 0.5) * cos(uv.y * 0.7) * 0.5;
    h += cos(uv.x * 1.2 - uv.y * 0.4) * 0.3;
    h += sin(uv.x * 0.3 + uv.y * 0.9) * 0.2;
    h = h * 0.5 + 0.5;
    // Hillshade (light from upper-left)
    float dx = dFdx(h) * 30.0;
    float dy = dFdy(h) * 30.0;
    float shade = 0.5 + 0.5 * (-dx + dy) / (length(vec2(dx, dy)) + 0.01);
    // Elevation colors
    vec3 low = vec3(0.0, 0.2, 0.5);
    vec3 mid = vec3(0.2, 0.6, 0.2);
    vec3 high = vec3(0.6, 0.5, 0.3);
    vec3 peak = vec3(0.95, 0.95, 0.95);
    vec3 col = h < 0.3 ? low : h < 0.5 ? mid : h < 0.75 ? high : peak;
    col *= shade;
    fragColor = vec4(col, 1.0);
}
