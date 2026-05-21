#version 310 es
precision highp float;
out vec4 fragColor;

float getColor(int i) {
    switch (i) {
        case 0: return 0.8;
        case 1: return 0.6;
        case 2: return 0.4;
        default: return 0.2;
    }
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int idx = int(floor(uv.x * 3.0 + 1.5));
    float val = getColor(idx);
    vec3 col = vec3(val);
    fragColor = vec4(col, 1.0);
}
