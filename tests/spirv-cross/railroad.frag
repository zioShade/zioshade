#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Railroad tracks with perspective
    // Vanishing point
    vec2 vp = vec2(5.0, 8.0);
    // Sky
    vec3 col = mix(vec3(0.4, 0.55, 0.8), vec3(0.7, 0.8, 0.95), uv.y / 10.0);
    // Ground
    col = mix(col, vec3(0.4, 0.55, 0.2), step(uv.y, 5.0));
    // Rails (converge to vanishing point)
    for (int i = -2; i <= 2; i++) {
        float offset = float(i) * 0.15;
        vec2 top = vp;
        vec2 bot = vec2(5.0 + offset * 5.0, 0.0);
        vec2 pa = uv - bot;
        vec2 ba = top - bot;
        float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * t);
        float rail = smoothstep(0.02, 0.01, d);
        col = mix(col, vec3(0.3, 0.3, 0.35), rail * step(0.0, uv.y) * step(uv.y, 5.0));
    }
    // Ties (horizontal lines)
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float y = fi * 0.6 + 0.3;
        float width = 0.4 + (y / 5.0) * 1.5;
        float tie = smoothstep(0.03, 0.01, abs(uv.y - y)) * step(5.0 - width, uv.x) * step(uv.x, 5.0 + width);
        col = mix(col, vec3(0.5, 0.35, 0.2), tie);
    }
    fragColor = vec4(col, 1.0);
}
