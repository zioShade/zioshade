#version 450
// Test: luminance threshold
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(uv, 0.5);
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    vec3 result = lum > 0.5 ? col : vec3(0.0);
    gl_FragColor = vec4(result, 1.0);
}
