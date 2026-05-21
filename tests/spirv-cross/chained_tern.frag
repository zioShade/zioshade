#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = uv.x > 0.0 ? sin(uv.y * 10.0) * 0.5 + 0.5 : cos(uv.x * 10.0) * 0.5 + 0.5;
    float b = uv.y > 0.0 ? a * 2.0 : a * 0.5;
    vec3 col = r < 0.5 ? vec3(a, b, a * b) : vec3(b, a, b - a);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
