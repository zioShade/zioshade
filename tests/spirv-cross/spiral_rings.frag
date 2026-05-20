#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float angle = atan(uv.y, uv.x);
    float radius = length(uv);
    float spiral = sin(angle * 5.0 - radius * 20.0) * 0.5 + 0.5;
    float rings = sin(radius * 30.0) * 0.5 + 0.5;
    vec3 col = mix(vec3(0.2, 0.5, 0.8), vec3(0.8, 0.3, 0.5), spiral);
    col = mix(col, vec3(1.0), rings * 0.3 * (1.0 - radius));
    col *= 1.0 - radius * 0.5;
    fragColor = vec4(col, 1.0);
}
