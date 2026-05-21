#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(uv.x * 8.0 + 4.0));
    sector = clamp(sector, 0, 8);
    float r; float g; float b;
    switch (sector) {
        case 0: r = 0.8; g = 0.1; b = 0.1; break;
        case 1: r = 0.8; g = 0.5; b = 0.1; break;
        case 2: r = 0.8; g = 0.8; b = 0.1; break;
        case 3: r = 0.1; g = 0.8; b = 0.1; break;
        case 4: r = 0.1; g = 0.8; b = 0.8; break;
        case 5: r = 0.1; g = 0.1; b = 0.8; break;
        case 6: r = 0.5; g = 0.1; b = 0.8; break;
        case 7: r = 0.8; g = 0.1; b = 0.5; break;
        default: r = 0.5; g = 0.5; b = 0.5; break;
    }
    vec3 col = vec3(r, g, b) * (0.7 + 0.3 * sin(uv.y * 10.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
