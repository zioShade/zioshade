#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Terraced rice fields
    float h = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        h += sin(uv.x * (1.0 + fi) + fi * 1.7) * cos(uv.y * (0.8 + fi * 0.5) + fi * 2.3) * 0.3 / (fi + 1.0);
    }
    h = h * 0.5 + 0.5;
    // Terrace levels
    float levels = 8.0;
    float terrace = floor(h * levels) / levels;
    float within = fract(h * levels);
    // Each terrace: green on top (rice), brown on side (wall)
    float wall = smoothstep(0.1, 0.05, within);
    vec3 rice = vec3(0.3, 0.6, 0.2);
    vec3 wall_col = vec3(0.5, 0.35, 0.2);
    vec3 water = vec3(0.3, 0.5, 0.7);
    vec3 col = h < 0.25 ? water : mix(rice, wall_col, wall);
    fragColor = vec4(col, 1.0);
}
