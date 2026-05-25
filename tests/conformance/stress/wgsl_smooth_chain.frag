// Tests: clamp, mix, step, smoothstep chain
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float a = smoothstep(0.2, 0.8, uv.x);
    float b = step(0.5, uv.y);
    float c = clamp(uv.x * uv.y, 0.0, 1.0);
    float d = mix(a, b, c);
    vec3 color = mix(vec3(0.1), vec3(0.9), d);
    fragColor = vec4(color, 1.0);
}
