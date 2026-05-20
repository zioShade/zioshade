#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Music visualizer bars
    float bars = 10.0;
    float bar_id = floor((uv.x + 1.0) * bars / 2.0);
    float bar_f = fract((uv.x + 1.0) * bars / 2.0);
    float h = fract(sin(bar_id * 127.1) * 43758.5);
    float height = 0.2 + h * 0.6;
    float bar = smoothstep(0.05, 0.0, min(bar_f, 1.0 - bar_f)) * step(uv.y, height) * step(-0.8, uv.y);
    vec3 col = vec3(0.05);
    vec3 bar_col = mix(vec3(0.2, 0.5, 1.0), vec3(1.0, 0.3, 0.2), uv.y / height);
    col += bar_col * bar;
    fragColor = vec4(col, 1.0);
}
