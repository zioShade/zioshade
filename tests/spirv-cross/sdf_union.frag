#version 310 es
precision highp float;
out vec4 fragColor;

float sdCircle(vec2 p, float r) { return length(p) - r; }
float sdBox(vec2 p, vec2 b) { vec2 d = abs(p) - b; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) * 0.01;
    float d1 = sdCircle(uv - vec2(-0.5, 0.0), 0.5);
    float d2 = sdBox(uv - vec2(0.5, 0.0), vec2(0.4));
    float d = min(d1, d2);
    vec3 col = vec3(1.0) - sign(d) * vec3(0.3, 0.5, 0.7);
    col *= 1.0 - exp(-3.0 * abs(d));
    col *= 0.8 + 0.2 * cos(32.0 * d);
    fragColor = vec4(col, 1.0);
}
