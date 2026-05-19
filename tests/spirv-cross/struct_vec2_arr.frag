#version 450
layout(location = 0) out vec4 FragColor;
struct Params {
    vec2 offsets[3];
    float scale;
};
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Params p;
    p.scale = 2.0;
    p.offsets[0] = vec2(0.0, 0.0);
    p.offsets[1] = vec2(0.5, 0.0);
    p.offsets[2] = vec2(0.0, 0.5);
    int idx = int(uv.x * 2.999);
    idx = clamp(idx, 0, 2);
    vec2 off = vec2(0.0);
    for (int i = 0; i < 3; i++) {
        if (i == idx) off = p.offsets[i];
    }
    float d = length(uv - off * p.scale);
    FragColor = vec4(vec3(smoothstep(0.3, 0.5, d)), 1.0);
}
