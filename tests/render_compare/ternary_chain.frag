
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = uv.x > 0.5 ? 1.0 : 0.2;
    float g = uv.y > 0.5 ? 0.8 : 0.1;
    float b = (uv.x + uv.y) > 0.8 ? 1.0 : 0.0;
    FragColor = vec4(r, g, b, 1.0);
}
