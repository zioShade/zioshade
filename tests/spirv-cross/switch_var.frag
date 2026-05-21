#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(uv.x * 4.0 + 2.0));
    float r; float g; float b;
    switch (sector) {
        case 0: r = 0.8; g = 0.2; b = 0.1; break;
        case 1: r = 0.1; g = 0.8; b = 0.2; break;
        case 2: r = 0.2; g = 0.1; b = 0.8; break;
        case 3: r = 0.8; g = 0.7; b = 0.1; break;
        default: r = 0.5; g = 0.5; b = 0.5; break;
    }
    vec3 col = vec3(r, g, b);
    fragColor = vec4(col, 1.0);
}
