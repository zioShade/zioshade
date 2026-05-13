
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    FragColor = vec4(uv.x, uv.y, 0.0, 1.0);
}
