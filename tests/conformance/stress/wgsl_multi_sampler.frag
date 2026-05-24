// Tests: multiple sampler bindings
#version 450
layout(binding = 0) uniform sampler2D tex0;
layout(binding = 1) uniform sampler2D tex1;
layout(binding = 2) uniform sampler2D tex2;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 fragColor;

void main() {
    vec4 c0 = texture(tex0, v_uv);
    vec4 c1 = texture(tex1, v_uv);
    vec4 c2 = texture(tex2, v_uv);
    fragColor = c0 * 0.5 + c1 * 0.3 + c2 * 0.2;
}
