#version 450
// Test: luminance to color
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float lum = sin(uv.x * 6.28) * cos(uv.y * 6.28) * 0.5 + 0.5;
    vec3 col = vec3(lum);
    gl_FragColor = vec4(col, 1.0);
}
