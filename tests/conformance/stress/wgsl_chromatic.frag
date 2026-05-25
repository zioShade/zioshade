// Tests: simple chromatic aberration pattern
#version 450
layout(location = 0) out vec4 fragColor;
uniform sampler2D u_tex;
uniform vec2 u_resolution;
uniform float u_strength;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec2 dir = uv - 0.5;
    float r = texture(u_tex, uv + dir * u_strength).r;
    float g = texture(u_tex, uv).g;
    float b = texture(u_tex, uv - dir * u_strength).b;
    fragColor = vec4(r, g, b, 1.0);
}
