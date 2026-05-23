#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // dFdx / dFdy derivatives
    float fx = dFdx(uv.x);
    float fy = dFdy(uv.y);
    float fw = fwidth(uv.x);
    fragColor = vec4(fx * 100.0, fy * 100.0, fw * 100.0, 1.0);
}
