// Tests: function returning struct, called from inside a ternary in a loop
precision mediump float;
uniform vec2 u_resolution;

struct Sample {
    float dist;
    vec3 color;
};

Sample circle(vec2 p, float r, vec3 col) {
    Sample s;
    s.dist = length(p) - r;
    s.color = col;
    return s;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 center = vec2(0.25 + fi * 0.15, 0.5);
        float radius = 0.1;
        vec3 tint = vec3(fract(fi * 0.37), fract(fi * 0.71), fract(fi * 0.13));
        
        Sample s = circle(uv - center, radius, tint);
        float edge = smoothstep(0.02, 0.0, s.dist);
        col = mix(col, s.color, edge);
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
