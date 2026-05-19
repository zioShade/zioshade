#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = distance(uv, vec2(0.5));
    float ripple = sin(d * 30.0) * exp(-d * 3.0);
    vec3 col = vec3(ripple * 0.5 + 0.5);
    gl_FragColor = vec4(col, 1.0);
}
