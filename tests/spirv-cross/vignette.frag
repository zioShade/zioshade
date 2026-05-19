#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = distance(uv, vec2(0.5));
    float vig = 1.0 - d * d * 2.0;
    vec3 col = vec3(0.8, 0.7, 0.6) * vig;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
