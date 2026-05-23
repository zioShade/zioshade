#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Discard pattern
    vec2 centered = uv - vec2(0.5);
    float dist = length(centered);
    if (dist > 0.5) discard;
    vec3 col = vec3(dist * 2.0);
    fragColor = vec4(col, 1.0);
}
