#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float x = uv.x;
    float y = uv.y;
    float r = 0.0;
    float g = 0.0;
    if ((x > 0.25 && x < 0.75) && (y > 0.25 && y < 0.75)) {
        r = 1.0;
    } else if (x < 0.5) {
        g = 0.5;
    } else {
        r = 0.3;
        g = 0.7;
    }
    FragColor = vec4(r, g, 0.5, 1.0);
}
