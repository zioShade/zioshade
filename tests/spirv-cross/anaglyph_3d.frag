#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Stereo pair with anaglyph
    float eye_sep = 0.03;
    float depth = 0.5 + 0.3 * sin(uv.x * 5.0) * cos(uv.y * 4.0);
    float parallax = eye_sep * depth;
    float left = sin((uv.x - parallax) * 30.0) * sin((uv.y) * 25.0);
    float right = sin((uv.x + parallax) * 30.0) * sin((uv.y) * 25.0);
    left = left * 0.5 + 0.5;
    right = right * 0.5 + 0.5;
    // Red-cyan anaglyph
    vec3 col = vec3(left, right, right);
    fragColor = vec4(col, 1.0);
}
