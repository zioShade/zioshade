#version 310 es
precision highp float;
layout(location = 0) out vec4 fragColor;
void main() {
    // Fallthrough chain with a BREAK in the middle and fallthrough into default.
    // sel=4 -> 1+2+4=7 ; sel=3 -> 2+4=6 ; sel=2 -> 4 (break stops)
    // sel=1 -> 8+16+32=56 ; sel=0 -> 16+32=48
    // Exercises the WGSL fallthrough-chain duplication with a mid-chain break.
    int sel = int(gl_FragCoord.x) % 5;
    int acc = 0;
    switch (sel) {
        case 4:    acc += 1;           // fallthrough
        case 3:    acc += 2;           // fallthrough
        case 2:    acc += 4; break;    // BREAK stops the chain here
        case 1:    acc += 8;           // fallthrough
        case 0:    acc += 16;          // fallthrough into default
        default:   acc += 32;          // fallthrough target (no direct hit)
    }
    fragColor = vec4(float(acc) / 255.0, 0.0, 0.0, 1.0);
}
