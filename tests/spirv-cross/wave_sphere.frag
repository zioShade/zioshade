#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float z = sqrt(max(0.0, 1.0 - r * r));
    vec3 normal = normalize(vec3(p, z));
    float wave = sin(normal.x * 10.0) * sin(normal.y * 10.0) * sin(normal.z * 10.0);
    vec3 col = vec3(wave * 0.5 + 0.5) * step(r, 1.0);
    gl_FragColor = vec4(col, 1.0);
}
