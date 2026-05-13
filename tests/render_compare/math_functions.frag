
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = abs(sin(uv.x * 6.28));
    float g = abs(cos(uv.y * 6.28));
    float b = sqrt(uv.x * uv.y);
    float a = clamp(uv.x + uv.y, 0.0, 1.0);
    FragColor = vec4(r, g, b, a);
}
