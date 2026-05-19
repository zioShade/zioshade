#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 z = uv;
    float val = 0.0;
    for (int i = 0; i < 8; i++) {
        z = abs(z) / dot(z, z) - vec2(0.5);
        val += length(z) * 0.1;
    }
    gl_FragColor = vec4(clamp(vec3(val * 0.3, val * 0.5, val * 0.8), 0.0, 1.0), 1.0);
}
