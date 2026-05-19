#version 450
// Test: 2-octave noise
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
        mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
        f.y);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float n = noise(uv * 6.0) * 0.7 + noise(uv * 12.0) * 0.3;
    gl_FragColor = vec4(vec3(n), 1.0);
}
