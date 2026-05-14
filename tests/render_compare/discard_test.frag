#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    if (mod(uv.x * 8.0, 2.0) < 1.0 && mod(uv.y * 8.0, 2.0) < 1.0) {
        discard;
    }
    FragColor = vec4(uv.x, uv.y, 0.5, 1.0);
}
