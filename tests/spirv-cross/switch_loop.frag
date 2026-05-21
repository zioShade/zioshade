#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 col = vec3(0.0);
    for (int i = 0; i < 4; i++) {
        float val;
        switch (i) {
            case 0: val = 0.3; break;
            case 1: val = 0.5; break;
            case 2: val = 0.7; break;
            case 3: val = 0.9; break;
            default: val = 0.1; break;
        }
        col += vec3(val * float(i) * 0.1);
    }
    col += uv.x * 0.2;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
