#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Voronoi stained glass
    float scale = 3.0;
    vec2 p = uv * scale;
    vec2 nearest_cell = vec2(0.0);
    float min_d = 100.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 cell = floor(p) + neighbor;
            float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
            vec2 point = neighbor + vec2(h, fract(h * 17.3)) - fract(p);
            float d = dot(point, point);
            if (d < min_d) {
                min_d = d;
                nearest_cell = cell;
            }
        }
    }
    // Color based on cell
    float h = fract(sin(dot(nearest_cell, vec2(127.1, 311.7))) * 43758.5);
    vec3 glass = vec3(
        sin(h * 6.28 + 0.0) * 0.3 + 0.5,
        sin(h * 6.28 + 2.09) * 0.3 + 0.5,
        sin(h * 6.28 + 4.18) * 0.3 + 0.5
    );
    // Dark edges
    float edge = smoothstep(0.02, 0.05, sqrt(min_d));
    vec3 col = glass * edge;
    // Lead border
    col = mix(vec3(0.1), col, edge);
    fragColor = vec4(col, 1.0);
}
