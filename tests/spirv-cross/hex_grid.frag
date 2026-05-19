#version 450
// Test: hexagonal grid approximation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 6.0;
    vec2 p = vec2(uv.x, uv.y * 1.1547);
    vec2 h = vec2(floor(p.x), floor(p.y));
    float d = length(fract(p) - 0.5);
    vec3 col = mix(vec3(0.3, 0.4, 0.5), vec3(0.8, 0.7, 0.6), step(0.4, d));
    gl_FragColor = vec4(col, 1.0);
}
