#version 450
// Test: polar coordinate conversion
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float theta = atan(p.y, p.x);
    float sectors = floor(theta / 0.7854);
    vec3 col = vec3(r, mod(sectors, 3.0) / 3.0, (theta + 3.14) / 6.28);
    gl_FragColor = vec4(col, 1.0);
}
