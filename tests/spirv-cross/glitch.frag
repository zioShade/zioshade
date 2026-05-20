#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Glitch / data corruption effect
    float t = floor(gl_FragCoord.y * 0.1);
    float h = fract(sin(t * 127.1) * 43758.5);
    // Horizontal shift based on random row
    float shift = step(0.9, h) * (fract(sin(t * 311.7) * 43758.5) - 0.5) * 0.2;
    vec2 glitched = vec2(uv.x + shift, uv.y);
    // Color bands
    float r = sin(glitched.x * 20.0 + glitched.y * 5.0) * 0.5 + 0.5;
    float g = sin(glitched.x * 15.0 + glitched.y * 8.0 + 1.0) * 0.5 + 0.5;
    float b = sin(glitched.x * 25.0 + glitched.y * 3.0 + 2.0) * 0.5 + 0.5;
    vec3 col = vec3(r, g, b) * 0.5;
    // Scanline
    float scan = smoothstep(0.02, 0.01, fract(uv.y * 50.0));
    col *= 0.8 + 0.2 * (1.0 - scan);
    fragColor = vec4(col, 1.0);
}
