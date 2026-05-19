#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float d = abs(uv.x) + abs(uv.y);
    float fill = 1.0 - smoothstep(0.8, 0.82, d);
    vec3 col = mix(vec3(0.1), vec3(0.9, 0.7, 0.2), fill);
    FragColor = vec4(col, 1.0);
}
