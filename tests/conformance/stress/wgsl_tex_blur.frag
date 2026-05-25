// Tests: struct with sampler member access pattern
#version 450
layout(location = 0) out vec4 fragColor;
uniform sampler2D u_tex;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec4 c0 = texture(u_tex, uv);
    vec4 c1 = texture(u_tex, uv + vec2(0.01, 0.0));
    vec4 c2 = texture(u_tex, uv + vec2(0.0, 0.01));
    vec4 blur = (c0 + c1 + c2) / 3.0;
    fragColor = blur;
}
