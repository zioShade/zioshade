#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = abs(uv - 0.5);
    float shield = max(p.x * 2.0, p.y * 2.5);
    float edge = smoothstep(0.45, 0.5, shield);
    float inner = 1.0 - smoothstep(0.0, 0.4, shield);
    vec3 col = mix(vec3(0.2, 0.3, 0.5), vec3(0.8, 0.6, 0.2), inner);
    col = mix(col, vec3(0.8, 0.8, 0.7), edge);
    gl_FragColor = vec4(col, 1.0);
}
