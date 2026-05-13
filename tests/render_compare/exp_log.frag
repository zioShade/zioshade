
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float r = exp(uv.x * 2.0 - 1.0) / 3.0;
    float g = log(uv.y * 5.0 + 1.0) / 2.0;
    float b = pow(uv.x, 3.0);
    FragColor = vec4(r, g, b, 1.0);
}
