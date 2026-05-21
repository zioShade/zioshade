#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Test: nested struct with array member
    struct Gradient { vec3 colors[3]; float t; };
    Gradient g;
    g.colors[0] = vec3(0.8, 0.1, 0.1);
    g.colors[1] = vec3(0.1, 0.8, 0.1);
    g.colors[2] = vec3(0.1, 0.1, 0.8);
    g.t = length(uv);
    
    int idx = int(min(floor(g.t * 3.0), 2.0));
    idx = max(idx, 0);
    vec3 col = g.colors[idx];
    col *= smoothstep(1.0, 0.3, g.t);
    fragColor = vec4(col, 1.0);
}
