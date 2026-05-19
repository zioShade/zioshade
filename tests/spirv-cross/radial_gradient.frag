#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float r = length(uv);
    float angle = atan(uv.y, uv.x) / 6.28318 + 0.5;
    vec3 col = mix(vec3(1.0, 0.3, 0.1), vec3(0.1, 0.3, 1.0), angle);
    col *= smoothstep(1.0, 0.3, r);
    FragColor = vec4(col, 1.0);
}
