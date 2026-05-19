#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float saw = fract(uv.x * 5.0);
    float tri = abs(fract(uv.y * 5.0) - 0.5) * 2.0;
    gl_FragColor = vec4(saw, tri, saw * tri, 1.0);
}
