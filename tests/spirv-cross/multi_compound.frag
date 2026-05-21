#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = 0.0, b = 0.0, c = 0.0;
    if (r < 0.3) {
        a = 1.0; b += 0.5; c *= 2.0;
    } else if (r < 0.6) {
        a += 0.5; b = 0.8; c += 1.0;
    } else {
        a *= 0.5; b += 0.3; c = 1.0;
    }
    vec3 col = vec3(a, b, c);
    fragColor = vec4(col, 1.0);
}
