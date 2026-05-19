#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float line = sin(uv.y * 100.0) * 0.5 + 0.5;
    vec3 col = vec3(uv, 0.5) * (0.7 + 0.3 * line);
    gl_FragColor = vec4(col, 1.0);
}
