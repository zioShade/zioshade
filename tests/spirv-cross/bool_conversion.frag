#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    bool b1 = bool(1);
    bool b2 = bool(0);
    bool b3 = bool(0.5);
    bool b4 = bool(uv.x);
    bvec2 bv2 = bvec2(uv.x > 0.0, uv.y > 0.0);
    bvec3 bv3 = bvec3(true, false, bool(uv.x));
    float val = float(b1) + float(b2) + float(b3) + float(b4);
    if (bv2.x) val += 0.1;
    if (bv3.z) val += 0.2;
    fragColor = vec4(clamp(vec3(val * 0.2), 0.0, 1.0), 1.0);
}
