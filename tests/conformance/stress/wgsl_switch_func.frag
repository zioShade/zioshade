#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

// Switch statement
float switchColor(int mode, float x) {
    switch (mode) {
        case 0: return sin(x);
        case 1: return cos(x);
        case 2: return abs(sin(x * 2.0));
        case 3: return fract(x);
        default: return x;
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    int mode = int(uv.y * 4.0) % 4;
    float val = switchColor(mode, uv.x * 6.28);
    fragColor = vec4(val, val * 0.5, 1.0 - val, 1.0);
}
