#version 450
// Test: additive and multiplicative blend
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(uv.x, 0.0, 0.0);
    vec3 b = vec3(0.0, uv.y, 0.0);
    vec3 c = vec3(0.0, 0.0, uv.x * uv.y);
    vec3 add = a + b + c;
    vec3 mul = a * 2.0 + b * 2.0 + c * 2.0;
    gl_FragColor = vec4(clamp(mix(add, mul, 0.5), 0.0, 1.0), 1.0);
}
