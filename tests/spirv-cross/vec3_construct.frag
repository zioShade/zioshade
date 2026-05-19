#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(uv.x, uv.y, uv.x * uv.y);
    col = pow(col, vec3(0.5));
    FragColor = vec4(col, 1.0);
}
