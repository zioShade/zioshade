#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    float a = floor(x * 0.1);
    float b = ceil(x * 0.1);
    float c = fract(x * 0.01);
    float d = mod(y, 50.0);
    float e = round(x * 0.05);
    fragColor = vec4(c, d / 50.0, e / 15.0, 1.0);
}
