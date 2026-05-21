#version 310 es
precision highp float;
out vec4 fragColor;

// Test: dynamic array indexing with loop
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 palette[4];
    palette[0] = vec3(0.8, 0.2, 0.2);
    palette[1] = vec3(0.2, 0.6, 0.2);
    palette[2] = vec3(0.2, 0.3, 0.8);
    palette[3] = vec3(0.8, 0.7, 0.1);
    
    float r = length(uv);
    int idx = int(min(floor(r * 6.0), 3.0));
    idx = max(idx, 0);
    vec3 col = palette[idx];
    col *= smoothstep(0.9, 0.5, r);
    fragColor = vec4(col, 1.0);
}
