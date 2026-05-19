#version 450
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float n = hash(floor(uv * 8.0));
    float col = n * 0.5 + 0.25;
    gl_FragColor = vec4(vec3(col), 1.0);
}
