
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float c = mod(floor(uv.x * 8.0) + floor(uv.y * 8.0), 2.0);
    FragColor = vec4(c, c, c, 1.0);
}
