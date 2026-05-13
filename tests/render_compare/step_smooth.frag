#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float aspect = 1.0;
    vec2 p = (uv - 0.5) * vec2(aspect, 1.0) * 2.0;
    float d = length(p);
    float mask = step(d, 0.8) - step(d, 0.75);
    float inner = smoothstep(0.0, 0.3, d);
    vec3 col = vec3(0.1) + mask * vec3(0.9, 0.7, 0.2) + (1.0 - mask) * inner * vec3(0.2, 0.3, 0.6);
    FragColor = vec4(col, 1.0);
}
