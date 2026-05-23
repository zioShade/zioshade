#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // Mat2 construction and multiply
    mat2 m = mat2(vec2(1.0, 0.0), vec2(0.0, 1.0));
    vec2 v = m * uv;
    fragColor = vec4(v, 0.0, 1.0);
}
