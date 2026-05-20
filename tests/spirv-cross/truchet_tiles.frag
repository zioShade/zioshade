#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Truchet tiles
    vec2 cell = floor(uv * 8.0);
    vec2 f = fract(uv * 8.0);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5453);
    float d;
    if (h > 0.5) {
        d = min(length(f - vec2(0.0, 0.0)), length(f - vec2(1.0, 1.0)));
    } else {
        d = min(length(f - vec2(1.0, 0.0)), length(f - vec2(0.0, 1.0)));
    }
    float arc = smoothstep(0.3, 0.28, d);
    vec3 col = mix(vec3(0.1), vec3(0.7, 0.4, 0.2), arc);
    fragColor = vec4(col, 1.0);
}
