#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // min/max/pow
    float v = min(uv.x, uv.y);
    float w = max(uv.x, uv.y);
    float p = pow(v, 2.0);
    fragColor = vec4(p, v, w, 1.0);
}
