#version 450
layout(location = 0) out vec4 FragColor;
vec3 blend(vec3 a, vec3 b, float t) {
    return a * (1.0 - t) + b * t;
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 red = vec3(1.0, 0.2, 0.1);
    vec3 blue = vec3(0.1, 0.2, 1.0);
    vec3 col = blend(red, blue, uv.x);
    col *= smoothstep(0.2, 0.8, uv.y);
    FragColor = vec4(col, 1.0);
}
