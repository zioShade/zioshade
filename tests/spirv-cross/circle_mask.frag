#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5);
    float mask = 1.0 - smoothstep(0.3, 0.32, d);
    vec3 col = vec3(uv, 0.5) * mask;
    gl_FragColor = vec4(col, 1.0);
}
