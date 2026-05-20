#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // TV scanlines
    float scanline = sin(gl_FragCoord.y * 3.14159) * 0.5 + 0.5;
    // Pixel grid
    vec2 pixel = floor(gl_FragCoord.xy / 4.0);
    float pixel_rand = fract(sin(dot(pixel, vec2(12.9898, 78.233))) * 43758.5453);
    // Signal
    float signal = sin(uv.x * 20.0 + uv.y * 5.0) * 0.5 + 0.5;
    signal += pixel_rand * 0.1;
    signal *= scanline;
    vec3 col = vec3(0.1, 0.8, 0.2) * signal;
    fragColor = vec4(col, 1.0);
}
