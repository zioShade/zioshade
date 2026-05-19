#version 450
vec3 hueShift(vec3 col, float shift) {
    float cosA = cos(shift);
    float sinA = sin(shift);
    vec3 k = vec3(0.57735);
    return col * cosA + cross(k, col) * sinA + k * dot(k, col) * (1.0 - cosA);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = hueShift(vec3(1.0, 0.3, 0.1), uv.x * 6.28);
    gl_FragColor = vec4(col * smoothstep(0.0, 1.0, uv.y), 1.0);
}
