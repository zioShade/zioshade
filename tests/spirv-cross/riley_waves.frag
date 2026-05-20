#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Op art wavy lines (Riley-style)
    float freq = 15.0;
    float warp = sin(uv.y * 3.0) * 0.3;
    float lines = sin((uv.x + warp) * freq) * 0.5 + 0.5;
    float bw = step(0.5, lines);
    vec3 col = mix(vec3(0.0), vec3(1.0), bw);
    col *= smoothstep(1.2, 0.5, length(uv));
    fragColor = vec4(col, 1.0);
}
