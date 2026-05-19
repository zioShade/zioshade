#version 450
// Test: mosaic/pixelate effect
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 pixel = floor(uv * 8.0) / 8.0;
    vec3 col = vec3(pixel, 0.5);
    gl_FragColor = vec4(col, 1.0);
}
