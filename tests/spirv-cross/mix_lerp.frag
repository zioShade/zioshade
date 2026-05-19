#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(1.0, 0.2, 0.1);
    vec3 b = vec3(0.1, 0.2, 1.0);
    vec3 c = mix(a, b, uv.x);
    c *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(c, 1.0);
}
