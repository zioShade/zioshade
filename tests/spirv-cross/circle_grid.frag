#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 4.0;
    vec2 cell = fract(uv) - 0.5;
    float d = length(cell);
    float circle = smoothstep(0.3, 0.32, d);
    vec3 col = mix(vec3(0.8, 0.3, 0.2), vec3(0.1), circle);
    gl_FragColor = vec4(col, 1.0);
}
