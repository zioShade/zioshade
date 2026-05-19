#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 8.0;
    vec2 cell = fract(uv) - 0.5;
    float d = length(cell);
    float dot2 = 1.0 - smoothstep(0.15, 0.2, d);
    gl_FragColor = vec4(dot2, dot2 * 0.8, dot2 * 0.5, 1.0);
}
