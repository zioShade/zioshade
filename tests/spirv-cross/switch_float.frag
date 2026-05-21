#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float t = uv.x * 3.0 + 1.5;
    float val = 0.0;
    switch (int(floor(t))) {
        case 0: val = 0.9; break;
        case 1: val = 0.6; break;
        case 2: val = 0.3; break;
        case 3: val = 0.7; break;
        case 4: val = 0.4; break;
        default: val = 0.1; break;
    }
    vec3 col = vec3(val * 0.8, val, val * 1.2);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
