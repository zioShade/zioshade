// Tests: struct with array member passed by value, dynamic index into array member
precision mediump float;
uniform vec2 u_resolution;

struct Gradient {
    vec3 colors[4];
    float offset;
};

float sampleGradient(Gradient g, float t) {
    int idx = int(t * 3.999);
    idx = clamp(idx, 0, 3);
    vec3 c = g.colors[idx]; // by-value struct, dynamic index into array member
    return c.r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Gradient g;
    g.colors[0] = vec3(1.0, 0.0, 0.0);
    g.colors[1] = vec3(0.0, 1.0, 0.0);
    g.colors[2] = vec3(0.0, 0.0, 1.0);
    g.colors[3] = vec3(1.0, 1.0, 0.0);
    g.offset = 0.5;
    
    float v = sampleGradient(g, uv.x);
    gl_FragColor = vec4(vec3(v), 1.0);
}
