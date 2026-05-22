#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // bvec4 with dynamic component access via arithmetic
    bvec4 b = bvec4(uv.x > 0.3, uv.y > 0.3, uv.x > 0.6, uv.y > 0.6);
    float count = 0.0;
    if (b.x) count += 0.25;
    if (b.y) count += 0.25;
    if (b.z) count += 0.25;
    if (b.w) count += 0.25;

    // bool conversion from int in loop
    for (int i = 0; i < 4; i++) {
        bool bi = bool(i);
        if (bi) count += 0.1;
    }

    // Chain of bool ops
    bool a = uv.x > 0.5;
    bool bb = uv.y > 0.5;
    bool c = !a && bb;
    bool d = a || !bb;
    if (c) count *= 0.5;
    if (d) count *= 1.5;

    fragColor = vec4(clamp(vec3(count), 0.0, 1.0), 1.0);
}
