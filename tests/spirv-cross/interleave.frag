#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float row = floor(uv.y * 20.0);
    float mask = mod(row, 2.0);
    vec3 a = vec3(0.9, 0.5, 0.2);
    vec3 b = vec3(0.2, 0.5, 0.9);
    vec3 col = mix(a, b, mask) * uv.x;
    gl_FragColor = vec4(col, 1.0);
}
