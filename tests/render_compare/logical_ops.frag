
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    bool inCircle = length(uv - 0.5) < 0.3;
    bool inSquare = abs(uv.x - 0.5) < 0.2 && abs(uv.y - 0.5) < 0.2;
    float r = inCircle && !inSquare ? 1.0 : 0.0;
    float g = inSquare && !inCircle ? 1.0 : 0.0;
    float b = inCircle && inSquare ? 1.0 : 0.0;
    FragColor = vec4(r, g, b, 1.0);
}
