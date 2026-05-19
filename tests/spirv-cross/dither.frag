#version 450
// Test: ordered dithering
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = uv.x;
    vec2 grid = floor(gl_FragCoord.xy / vec2(128.0) * 4.0);
    float threshold = fract(sin(dot(grid, vec2(12.9898, 78.233))) * 43758.5453);
    float dithered = val > threshold ? 1.0 : 0.0;
    vec3 col = mix(vec3(0.1), vec3(0.9), dithered);
    gl_FragColor = vec4(col, 1.0);
}
