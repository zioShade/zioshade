#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(uv, 0.5);
    gl_FragColor = vec4(1.0 - col, 1.0);
}
