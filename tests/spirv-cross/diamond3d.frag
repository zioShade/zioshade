#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = abs(uv - 0.5) * 2.0;
    float d = p.x + p.y;
    vec3 col = vec3(1.0, 0.8, 0.3) * smoothstep(1.0, 0.0, d);
    gl_FragColor = vec4(col, 1.0);
}
