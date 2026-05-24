// Tests: fragment shader with multiple inputs and discard
#version 450
uniform float u_cutoff;
layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in float v_alpha;
layout(location = 0) out vec4 fragColor;

void main() {
    if (v_alpha < u_cutoff) discard;
    vec3 n = normalize(v_normal);
    float light = max(dot(n, vec3(0.577)), 0.0);
    fragColor = vec4(vec3(light) * v_uv.x, v_alpha);
}
