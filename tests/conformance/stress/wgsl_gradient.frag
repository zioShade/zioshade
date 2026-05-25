// Tests: simple gradient with math chain
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float angle = atan(uv.y - 0.5, uv.x - 0.5);
    float radius = length(uv - 0.5);
    float pattern = sin(angle * 3.0 + radius * 10.0) * 0.5 + 0.5;
    vec3 color = mix(vec3(0.1, 0.2, 0.4), vec3(0.9, 0.7, 0.3), pattern);
    fragColor = vec4(color, 1.0);
}
