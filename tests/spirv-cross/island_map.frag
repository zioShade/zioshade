#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Topographic island with water
    float h = 0.0;
    h += sin(uv.x * 0.5) * cos(uv.y * 0.7) * 0.5;
    h += cos(uv.x * 1.0 - uv.y * 0.5) * 0.3;
    h += sin(uv.x * 1.5 + uv.y * 1.2) * 0.15;
    h = h * 0.5 + 0.5;
    // Water level
    float water_level = 0.4;
    float is_water = step(h, water_level);
    vec3 water = vec3(0.1, 0.3, 0.6) * (0.8 + 0.2 * sin(uv.x * 3.0 + uv.y * 2.0));
    // Land coloring by height
    vec3 beach = vec3(0.85, 0.8, 0.6);
    vec3 forest = vec3(0.15, 0.5, 0.15);
    vec3 mountain = vec3(0.5, 0.4, 0.3);
    vec3 snow = vec3(0.95);
    float land_h = (h - water_level) / (1.0 - water_level);
    vec3 land = land_h < 0.1 ? beach : land_h < 0.5 ? forest : land_h < 0.8 ? mountain : snow;
    vec3 col = is_water > 0.5 ? water : land;
    fragColor = vec4(col, 1.0);
}
