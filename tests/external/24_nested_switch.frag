#version 450
// Regression guard: a nested switch drives the WGSL switch/loop replay path,
// where OpSelectionMerge (a structured-control-flow hint with no result) was
// leaking into the output as `let v = SelectionMerge();` — naga rejects it.
// SelectionMerge/LoopMerge must be skipped in that path.
layout(location = 0) in vec2 v;
layout(location = 0) out vec4 fragColor;
void main() {
    int mode = int(v.x) % 4;
    int sub = int(v.y) % 2;
    vec3 color = vec3(0.0);
    switch (mode) {
        case 0: color = vec3(1.0, 0.0, 0.0); break;
        case 1: {
            switch (sub) {
                case 0: color = vec3(0.0, 1.0, 0.0); break;
                default: color = vec3(0.0, 0.0, 1.0); break;
            }
            break;
        }
        default: color = vec3(0.5); break;
    }
    fragColor = vec4(color, 1.0);
}
