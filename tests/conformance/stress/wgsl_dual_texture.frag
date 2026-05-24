// Tests: texture sampling with uniform binding
#version 450
layout(binding = 0) uniform sampler2D uTex;
layout(binding = 1) uniform sampler2D uTex2;
uniform float u_blend;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 c1 = texture(uTex, v_uv);
    vec4 c2 = texture(uTex2, v_uv);
    fragColor = mix(c1, c2, u_blend);
}
