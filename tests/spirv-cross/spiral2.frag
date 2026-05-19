#version 450
// Test: spiral pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float spiral = sin(a * 3.0 + r * 20.0);
    vec3 col = vec3(spiral * 0.5 + 0.5);
    gl_FragColor = vec4(col, 1.0);
}
