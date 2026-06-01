#version 450
// Tests: not(bvec) relational builtin (OpLogicalNot over a boolean vector)
layout(location = 0) out vec4 fragColor;

void main() {
    bvec2 lt = lessThan(gl_FragCoord.xy, vec2(0.5, 0.5));
    bvec2 n = not(lt);
    fragColor = vec4(float(n.x), float(n.y), 0.0, 1.0);
}
