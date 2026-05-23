#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Integer bitwise ops
    int a = int(uv.x * 255.0);
    int b = int(uv.y * 255.0);
    int c = a & b;
    int d = a | b;
    int e = a ^ b;
    fragColor = vec4(float(c) / 255.0, float(d) / 255.0, float(e) / 255.0, 1.0);
}
