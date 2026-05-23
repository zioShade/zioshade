#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // vec4 swizzle shuffle
    vec4 a = vec4(0.1, 0.2, 0.3, 0.4);
    vec4 b = a.wzyx;  // reverse
    vec4 c = a.xyzw;  // identity
    vec2 d = a.xz;    // sparse
    fragColor = vec4(b.x + uv.x, c.y + uv.y, d.x, 1.0);
}
