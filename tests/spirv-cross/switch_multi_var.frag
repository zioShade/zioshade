#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(uv.x * 3.0 + 1.5));
    float a; float b; float c; float d;
    switch (sector) {
        case 0: a = 0.8; b = 0.2; c = 0.1; d = 0.5; break;
        case 1: a = 0.1; b = 0.7; c = 0.3; d = 0.4; break;
        case 2: a = 0.3; b = 0.4; c = 0.8; d = 0.6; break;
        default: a = 0.5; b = 0.5; c = 0.5; d = 0.5; break;
    }
    vec3 col = vec3(a + b * d, c, a * c + b);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
