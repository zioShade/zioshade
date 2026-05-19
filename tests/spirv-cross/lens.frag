#version 450
// Test: lens distortion pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);
    float rings = sin(r * 20.0) * sin(angle * 6.0);
    vec3 col = vec3(rings * 0.5 + 0.5);
    gl_FragColor = vec4(col, 1.0);
}
