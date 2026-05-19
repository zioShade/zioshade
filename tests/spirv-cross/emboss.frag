#version 450
// Test: emboss effect via derivatives
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float h = sin(uv.x * 10.0) * cos(uv.y * 10.0);
    float dx = dFdx(h);
    float dy = dFdy(h);
    float emboss = (dx + dy) * 2.0 + 0.5;
    gl_FragColor = vec4(vec3(emboss), 1.0);
}
