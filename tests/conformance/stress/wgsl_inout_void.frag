// Tests: void function with inout parameter (not inlined)
// Uses a counter-based pattern to prevent optimizer inlining
#version 450
uniform int u_mode;

void transform(inout vec2 p) {
    p.x = p.x * 2.0 - 1.0;
    p.y = p.y * 2.0 - 1.0;
}

void main() {
    vec2 coord = vec2(0.5);
    if (u_mode == 1) {
        transform(coord);
    } else {
        coord = coord * 3.0;
    }
    gl_FragColor = vec4(coord, 0.0, 1.0);
}
