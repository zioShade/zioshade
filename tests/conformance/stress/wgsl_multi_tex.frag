// Tests: multiple texture samples with coordinate manipulation
#version 450
layout(location = 0) out vec4 fragColor;
uniform sampler2D u_tex0;
uniform sampler2D u_tex1;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec4 c0 = texture(u_tex0, uv);
    vec4 c1 = texture(u_tex1, uv * 0.5 + 0.25);
    vec4 c2 = texture(u_tex0, uv + vec2(0.01));
    vec4 result = mix(c0, c1, 0.5) + c2 * 0.25;
    fragColor = result;
}
