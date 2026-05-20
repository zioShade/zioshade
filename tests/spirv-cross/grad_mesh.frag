#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Gradient mesh (bilinear interpolation)
    vec2 f = uv * 0.5 + 0.5;
    vec3 c00 = vec3(0.9, 0.2, 0.3);
    vec3 c10 = vec3(0.3, 0.8, 0.2);
    vec3 c01 = vec3(0.2, 0.3, 0.9);
    vec3 c11 = vec3(0.9, 0.8, 0.1);
    vec3 bot = mix(c00, c10, f.x);
    vec3 top = mix(c01, c11, f.x);
    vec3 col = mix(bot, top, f.y);
    fragColor = vec4(col, 1.0);
}
