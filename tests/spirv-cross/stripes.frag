#version 450
// Test: horizontal stripes with varying width
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float y = uv.y * 10.0;
    float stripe = step(0.5, fract(y));
    vec3 col = mix(vec3(0.9, 0.8, 0.7), vec3(0.2, 0.15, 0.1), stripe);
    gl_FragColor = vec4(col * smoothstep(0.0, 0.3, uv.x), 1.0);
}
