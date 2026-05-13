
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    int x = int(uv.x * 255.0);
    int y = int(uv.y * 255.0);
    int z = x ^ y;
    float c = float(z & 0xFF) / 255.0;
    FragColor = vec4(c, c, c, 1.0);
}
