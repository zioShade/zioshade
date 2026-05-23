#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float r = abs(sin(uv.x * 3.14159));
    float g = abs(cos(uv.y * 3.14159));
    float b = sqrt(r * r + g * g);
    fragColor = vec4(r, g, b, 1.0);
}
