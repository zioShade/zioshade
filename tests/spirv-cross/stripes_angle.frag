#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float angle = 0.5;
    mat2 rot = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    vec2 ruv = rot * uv;
    float stripe = sin(ruv.x * 20.0) * 0.5 + 0.5;
    FragColor = vec4(vec3(stripe), 1.0);
}
