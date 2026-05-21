#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a; float b; float c;
    if (r < 0.4) {
        a = 1.0; b = 0.5; c = 0.3;
    } else {
        a = 0.2; b = 0.8; c = 0.6;
    }
    vec3 col = vec3(a, b, c);
    fragColor = vec4(col, 1.0);
}
