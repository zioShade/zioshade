#version 450
// Test: bevel/emboss via step
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float left = step(0.3, uv.x);
    float right = step(uv.x, 0.7);
    float top = step(0.3, uv.y);
    float bottom = step(uv.y, 0.7);
    float mask = left * right * top * bottom;
    float highlight = step(0.3, uv.x) * step(uv.x, 0.35) * top * bottom;
    float shadow = step(0.65, uv.x) * step(uv.x, 0.7) * top * bottom;
    vec3 col = vec3(0.5) * mask + vec3(0.7) * highlight + vec3(0.3) * shadow;
    gl_FragColor = vec4(col, 1.0);
}
