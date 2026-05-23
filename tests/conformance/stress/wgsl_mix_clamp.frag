#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float val = mix(0.0, 1.0, uv.x);
    vec3 col = vec3(val);
    col = clamp(col, vec3(0.2), vec3(0.8));
    fragColor = vec4(col, 1.0);
}
