#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x - 150.0;
    float y = gl_FragCoord.y - 150.0;
    float a = abs(x);
    float b = sign(x);
    float c = -x;
    float d = abs(y);
    float e = sign(y);
    vec3 v = vec3(a * 0.01, b * 0.5 + 0.5, c * 0.005 + 0.5);
    fragColor = vec4(v, 1.0);
}
