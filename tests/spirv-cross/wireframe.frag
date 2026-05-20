#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // 3D wireframe cube
    // 8 vertices of a unit cube
    float s = 0.5;
    // Front face
    float f1 = line_seg_dist(uv, vec2(-s, -s), vec2(s, -s));
    float f2 = line_seg_dist(uv, vec2(s, -s), vec2(s, s));
    float f3 = line_seg_dist(uv, vec2(s, s), vec2(-s, s));
    float f4 = line_seg_dist(uv, vec2(-s, s), vec2(-s, -s));
    float min_d = min(min(f1, f2), min(f3, f4));
    float wire = smoothstep(0.01, 0.005, min_d);
    vec3 col = vec3(0.3, 0.6, 1.0) * wire;
    fragColor = vec4(col, 1.0);
}

float line_seg_dist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * t);
}
