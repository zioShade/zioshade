#version 450
// Test: tile repeat pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 tile = fract(uv * 4.0);
    float d = min(tile.x, tile.y);
    vec3 col = vec3(step(0.1, d));
    gl_FragColor = vec4(col, 1.0);
}
