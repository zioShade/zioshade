#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // Boolean logic
    bool b1 = uv.x > 0.5;
    bool b2 = uv.y > 0.5;
    float r = b1 ? 1.0 : 0.0;
    float g = b2 ? 1.0 : 0.0;
    float bl = (b1 && b2) ? 1.0 : 0.0;
    fragColor = vec4(r, g, bl, 1.0);
}
