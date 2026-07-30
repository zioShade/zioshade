#version 310 es
precision highp float;
layout(location = 0) out vec4 fragColor;
void main() {
    // Loop INSIDE a switch case body (OpLoopMerge between OpSwitch and switch merge).
    // WGSL backend should honest-error (loop-in-switch-case); MSL/GLSL/HLSL should render.
    int sel = int(gl_FragCoord.x) % 3;
    int outv = 0;
    switch (sel) {
        case 0:
            for (int i = 0; i < 3; i++) { outv += i; }   // loop in case body
            break;
        case 1:
            outv = 100;
            break;
        default:
            outv = 200;
            break;
    }
    fragColor = vec4(float(outv) / 255.0, 0.0, 0.0, 1.0);
}
