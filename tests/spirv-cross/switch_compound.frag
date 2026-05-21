#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(uv.x * 3.0 + 1.5));
    float val = 0.0;
    switch (sector) {
        case 0: val = 0.8; break;
        case 1: val = 0.5; break;
        case 2: val = 0.2; break;
        default: val = 0.3; break;
    }
    val *= 2.0;
    val += 0.1 * sin(uv.y * 5.0);
    vec3 col = vec3(val);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
