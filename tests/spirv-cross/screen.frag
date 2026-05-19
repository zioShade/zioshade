#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = gl_FragCoord.xy;
    float pixel = mod(p.x + p.y, 2.0);
    vec3 col = vec3(uv, 0.5) * (0.8 + 0.2 * pixel);
    gl_FragColor = vec4(col, 1.0);
}
