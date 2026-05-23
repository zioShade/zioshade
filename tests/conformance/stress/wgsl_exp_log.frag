#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // exp, log, exp2, log2, sqrt, inversesqrt
    float e = exp(uv.x);
    float l = log(e);
    float e2 = exp2(uv.y);
    float l2 = log2(e2);
    float s = sqrt(uv.x);
    float is = inversesqrt(max(uv.y, 0.01));
    fragColor = vec4(l, l2, s, 1.0);
}
