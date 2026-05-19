#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float x = p.x / (p.y + 1.5);
    float z = 1.0 / (p.y + 1.5);
    float grid = step(0.1, abs(fract(x * 3.0) - 0.5)) * step(0.1, abs(fract(z * 3.0) - 0.5));
    vec3 col = mix(vec3(0.2, 0.5, 0.3), vec3(0.05, 0.1, 0.05), grid) * (1.0 - uv.y * 0.5);
    gl_FragColor = vec4(col, 1.0);
}
