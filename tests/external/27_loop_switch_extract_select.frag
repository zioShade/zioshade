#version 450
// Regression guard: a while(true)+switch state machine drives the WGSL
// switch/loop replay path (emitSimpleInstruction). OpCompositeExtract and
// OpSelect there previously fell to the generic fallback, leaking the opcode
// name and an access-expr-as-var-name (`var v.x: f32 = CompositeExtract(...)`,
// `Select(...)`) which naga rejects. They must lower to an inline access
// expression and `select(...)` respectively.
layout(location = 0) in vec3 v;
layout(location = 0) out vec4 o;
void main() {
    int state = 0;
    vec3 acc = vec3(0.0);
    while (true) {
        switch (state) {
            case 0: acc.x = v.x; state = (v.x > 0.5) ? 2 : 1; break;
            case 1: acc.y = v.y; state = 3; break;
            default: state = 3; break;
        }
        if (state == 3) break;
    }
    o = vec4(acc, 1.0);
}
