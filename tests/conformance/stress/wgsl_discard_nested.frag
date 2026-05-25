// Tests: early discard in nested control flow
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    if (uv.x < 0.1 || uv.x > 0.9) discard;
    if (uv.y < 0.1 || uv.y > 0.9) discard;

    float r = sin(uv.x * 10.0) * 0.5 + 0.5;
    float g = cos(uv.y * 10.0) * 0.5 + 0.5;
    fragColor = vec4(r, g, 0.5, 1.0);
}
