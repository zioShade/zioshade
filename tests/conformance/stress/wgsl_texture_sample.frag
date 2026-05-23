#version 450
layout(binding = 0) uniform sampler2D u_tex;
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;
void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec4 c = texture(u_tex, uv);
    vec4 d = textureLod(u_tex, uv, 0.0);
    fragColor = c + d;
}
