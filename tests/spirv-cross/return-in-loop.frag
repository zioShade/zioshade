#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Return inside a loop causes dominance violation if the optimizer
    // removes the fresh load of uv in the merge block
    for (int i = 0; i < 10; i++) {
        vec2 loaded_uv = uv;
        if (loaded_uv.x > 0.9) {
            fragColor = vec4(1.0, 0.0, 0.0, 1.0);
            return;
        }
    }
    // This uses uv.y AFTER the loop — the optimizer must not reuse
    // the load from inside the loop body here
    fragColor = vec4(0.0, uv.y, 0.0, 1.0);
}
