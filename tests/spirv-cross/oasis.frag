#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Desert oasis with palm tree
    vec3 sky = mix(vec3(0.4, 0.6, 0.9), vec3(0.8, 0.7, 0.5), smoothstep(5.0, 10.0, uv.y));
    vec3 sand = vec3(0.9, 0.82, 0.6);
    vec3 water = vec3(0.2, 0.5, 0.7);
    vec3 col = sky;
    // Ground
    col = mix(col, sand, step(uv.y, 4.0));
    // Water pool
    float pool = smoothstep(2.5, 2.3, length(uv - vec2(6.0, 3.5)));
    col = mix(col, water * (0.8 + 0.2 * sin(uv.x * 5.0)), pool * step(uv.y, 4.0));
    // Palm trunk
    float trunk = smoothstep(0.08, 0.05, abs(uv.x - 5.0 - sin((uv.y - 4.0) * 0.5) * 0.1)) * step(4.0, uv.y) * step(uv.y, 7.5);
    col = mix(col, vec3(0.45, 0.3, 0.1), trunk);
    // Palm fronds
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float angle = fi * 1.047 - 0.5;
        vec2 dir = vec2(cos(angle), sin(angle));
        float proj = dot(uv - vec2(5.0, 7.5), dir);
        float perp = abs(dot(uv - vec2(5.0, 7.5), vec2(-sin(angle), cos(angle))));
        float frond = smoothstep(0.04, 0.02, perp - proj * 0.02) * step(0.0, proj) * step(proj, 1.5);
        col = mix(col, vec3(0.15, 0.5, 0.1), frond);
    }
    fragColor = vec4(col, 1.0);
}
