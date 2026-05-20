#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Honeycomb close-pack (proper hex grid)
    float scale = 5.0;
    vec2 p = uv * scale;
    // Hex grid via axial coordinates
    vec2 hex_size = vec2(1.0, 0.866);
    vec2 h = p / hex_size;
    // Round to nearest hex center
    float r_x = round(h.x);
    float r_y = round(h.y);
    float r_z = round(-h.x - h.y);
    float x_diff = abs(r_x - h.x);
    float y_diff = abs(r_y - h.y);
    float z_diff = abs(r_z - (-h.x - h.y));
    if (x_diff > y_diff && x_diff > z_diff) {
        r_x = -r_y - r_z;
    } else if (y_diff > z_diff) {
        r_y = -r_x - r_z;
    } else {
        r_z = -r_x - r_y;
    }
    vec2 center = vec2(r_x, r_y) * hex_size;
    float d = length(p - center);
    float hex = smoothstep(0.55, 0.52, d);
    float n = fract(sin(r_x * 127.1 + r_y * 311.7) * 43758.5);
    vec3 col = vec3(0.8, 0.65, 0.1) * hex * (0.7 + 0.3 * n);
    col += vec3(0.1) * (1.0 - hex);
    fragColor = vec4(col, 1.0);
}
