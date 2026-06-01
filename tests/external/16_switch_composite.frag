#version 450
// Regression guard: a CompositeConstruct (vector constructor) whose result is
// USED inside a switch-case body (not just stored) must emit `vec4f(...)` in
// WGSL, not leak the opcode tag name `CompositeConstruct(...)` (which the
// loop/switch-replay path previously did → naga "no definition in scope").
layout(location = 0) flat in int sel;
layout(location = 0) out vec4 o;

void main() {
    vec4 c = vec4(0.0);
    switch (sel) {
        case 1:
            c = c + vec4(1.0, 2.0, 3.0, 4.0);
            break;
        case 2:
            c = c + vec4(5.0, 6.0, 7.0, 8.0);
            break;
        default:
            c = vec4(9.0);
            break;
    }
    o = c;
}
