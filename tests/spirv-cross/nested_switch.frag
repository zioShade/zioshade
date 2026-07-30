#version 310 es
precision highp float;
layout(location = 0) out vec4 fragColor;
void main() {
    // switch-in-switch: outer on x, inner on y in EACH case body.
    int x = int(gl_FragCoord.x) % 3;
    int y = int(gl_FragCoord.y) % 3;
    int outv = 0;
    switch (x) {
        case 0:
            switch (y) {
                case 0:  outv = 10; break;
                case 1:  outv = 11; break;
                default: outv = 12; break;
            }
            break;
        case 1:
            switch (y) {
                case 0:  outv = 20; break;
                case 1:  outv = 21; break;
                default: outv = 22; break;
            }
            break;
        default:
            switch (y) {
                case 0:  outv = 30; break;
                case 1:  outv = 31; break;
                default: outv = 32; break;
            }
            break;
    }
    fragColor = vec4(float(outv) / 255.0, 0.0, 0.0, 1.0);
}
