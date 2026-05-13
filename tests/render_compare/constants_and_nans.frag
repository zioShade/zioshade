
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = max(uv.x, 0.0);
    float g = min(uv.y, 1.0);
    float b = ceil(uv.x * 4.0) / 4.0;
    float a = floor(uv.y * 4.0) / 4.0;
    FragColor = vec4(r, g, b, 1.0);
}
