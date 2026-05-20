#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    float f = sin(uv.x) * cos(uv.y);
    // Derivatives of complex expressions
    float dx = dFdx(f);
    float dy = dFdy(f);
    float fw = fwidth(f);
    vec2 grad = vec2(dx, dy);
    // Conditional derivatives
    float g = uv.x > 0.5 ? dFdx(sin(uv.x * 10.0)) : dFdy(cos(uv.y * 10.0));
    fragColor = vec4(grad, fw, g);
}
