#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float r = length(uv);
    float angle = atan(uv.y, uv.x);
    float spiral = sin(angle * 3.0 + r * 15.0) * 0.5 + 0.5;
    spiral *= smoothstep(1.0, 0.2, r);
    FragColor = vec4(vec3(spiral), 1.0);
}
