#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Concentric diamond pattern with rotation
    float angle = 0.3;
    float c = cos(angle);
    float s = sin(angle);
    vec2 rotated = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    float d = abs(rotated.x) + abs(rotated.y);
    float rings = sin(d * 20.0) * 0.5 + 0.5;
    rings = step(0.5, rings);
    vec3 col = mix(vec3(0.1), vec3(0.7, 0.5, 0.3), rings) * smoothstep(1.2, 0.5, length(uv));
    fragColor = vec4(col, 1.0);
}
