#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Blueprint technical drawing v2
    vec3 col = vec3(0.05, 0.12, 0.3);
    float grid = smoothstep(0.02, 0.01, min(fract(uv.x), fract(uv.y)));
    col += vec3(0.1, 0.2, 0.4) * grid * 0.3;
    float major = smoothstep(0.02, 0.01, min(fract(uv.x * 0.2), fract(uv.y * 0.2)));
    col += vec3(0.15, 0.25, 0.45) * major * 0.5;
    float d = length(uv - vec2(5.0, 5.0));
    float circle = smoothstep(0.02, 0.01, abs(d - 3.0));
    col += vec3(0.6, 0.8, 1.0) * circle;
    float cx = smoothstep(0.02, 0.01, abs(uv.x - 5.0)) * step(2.0, uv.y) * step(uv.y, 8.0);
    float cy = smoothstep(0.02, 0.01, abs(uv.y - 5.0)) * step(2.0, uv.x) * step(uv.x, 8.0);
    col += vec3(0.6, 0.8, 1.0) * (cx + cy);
    fragColor = vec4(col, 1.0);
}
