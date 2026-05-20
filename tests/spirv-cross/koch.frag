#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Koch snowflake approximation
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Iterative refinement
    float d = 100.0;
    vec2 p = uv;
    for (int i = 0; i < 4; i++) {
        // Scale and replicate
        p *= 3.0;
        vec2 cell = floor(p);
        p = fract(p);
        // Keep only edge triangles
        float tri = max(abs(p.x + p.y - 1.0), max(-p.x, -p.y));
        d = min(d, tri / pow(3.0, float(i)));
    }
    float flake = smoothstep(0.02, 0.0, d);
    vec3 col = vec3(0.1, 0.2, 0.4) + vec3(0.7, 0.85, 1.0) * flake;
    fragColor = vec4(col, 1.0);
}
