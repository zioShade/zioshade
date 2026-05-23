#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // Nested function calls
    float d = length(uv - vec2(0.5));
    float s = sin(d * 6.28);
    float a = abs(s);
    float p = pow(a, 0.5);
    fragColor = vec4(p, p, p, 1.0);
}
