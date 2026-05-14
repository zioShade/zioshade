#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    if (uv.x > 0.75) {
        FragColor = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }
    if (uv.y > 0.75) {
        FragColor = vec4(0.0, 1.0, 0.0, 1.0);
        return;
    }
    FragColor = vec4(uv.x, uv.y, 0.5, 1.0);
}
