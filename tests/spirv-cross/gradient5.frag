#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = vec3(0.0, 0.0, 1.0);
    vec3 col = uv.x < 0.5 ? mix(a, b, uv.x * 2.0) : mix(b, c, (uv.x - 0.5) * 2.0);
    col *= smoothstep(0.0, 1.0, uv.y);
    gl_FragColor = vec4(col, 1.0);
}
