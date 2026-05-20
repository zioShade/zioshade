#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Star of David
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Two overlapping triangles
    float tri1 = smoothstep(0.5, 0.48, r) * step(0.0, cos(a * 3.0));
    float tri2 = smoothstep(0.5, 0.48, r) * step(0.0, cos((a + 0.5236) * 3.0));
    float star = max(tri1, tri2);
    // Inner hexagon
    float hex_a = abs(mod(a, 1.0472) - 0.5236);
    float hex_r = 0.22 / cos(hex_a);
    float hex = smoothstep(hex_r + 0.01, hex_r - 0.01, r);
    vec3 blue = vec3(0.1, 0.2, 0.7);
    vec3 white = vec3(0.95);
    vec3 col = vec3(0.05);
    col = mix(col, blue, star);
    col = mix(col, white, hex);
    fragColor = vec4(col, 1.0);
}
