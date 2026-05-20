#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Zebra stripes with distortion
    float distortion = sin(uv.y * 3.0) * 0.5 + sin(uv.y * 7.0 + uv.x * 2.0) * 0.3;
    float stripe = sin((uv.x + distortion) * 6.0) * 0.5 + 0.5;
    float bw = step(0.5, stripe);
    vec3 col = mix(vec3(0.05), vec3(0.9), bw);
    // Fade at edges
    float edge_x = smoothstep(0.0, 1.0, uv.x) * smoothstep(15.0, 14.0, uv.x);
    col *= edge_x;
    fragColor = vec4(col, 1.0);
}
