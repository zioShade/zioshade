#version 450
// Test: barrel distortion
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r2 = dot(p, p);
    vec2 distorted = p * (1.0 + 0.3 * r2);
    vec3 col = vec3(distorted * 0.5 + 0.5, 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
