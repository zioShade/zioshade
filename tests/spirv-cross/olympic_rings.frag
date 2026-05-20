#version 310 es
precision highp float;
out vec4 fragColor;

float circle(vec2 uv, vec2 center, float radius) {
    return smoothstep(radius + 0.01, radius, length(uv - center));
}

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    float pattern = 0.0;
    pattern += circle(uv, vec2(1.0, 1.0), 0.5);
    pattern += circle(uv, vec2(2.0, 1.0), 0.5);
    pattern += circle(uv, vec2(1.5, 1.87), 0.5);
    pattern += circle(uv, vec2(1.5, 0.5), 0.3);
    vec3 col = mix(vec3(0.1), vec3(0.3, 0.6, 0.9), clamp(pattern, 0.0, 1.0));
    fragColor = vec4(col, 1.0);
}
