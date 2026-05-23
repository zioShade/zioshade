#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float d = length(uv - vec2(0.5));
    float alpha = smoothstep(0.3, 0.2, d);
    vec3 inner = vec3(1.0, 0.5, 0.0);
    vec3 outer = vec3(0.0, 0.2, 0.4);
    vec3 col = mix(outer, inner, alpha);
    fragColor = vec4(col, 1.0);
}
