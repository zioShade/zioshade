// Tests: struct with vec2 array member accessed in conditional
precision mediump float;
uniform vec2 u_resolution;

struct Gradient {
    vec3 colors[3];
    float offset;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Gradient g;
    g.colors[0] = vec3(1.0, 0.0, 0.0);
    g.colors[1] = vec3(0.0, 1.0, 0.0);
    g.colors[2] = vec3(0.0, 0.0, 1.0);
    g.offset = 0.1;
    
    // Conditional modification of struct member
    if (uv.x > 0.5) {
        g.colors[1] = vec3(1.0, 1.0, 0.0);
        g.offset = 0.2;
    }
    
    float t = fract(uv.y + g.offset);
    vec3 col;
    if (t < 0.333) {
        col = mix(g.colors[0], g.colors[1], t * 3.0);
    } else if (t < 0.667) {
        col = mix(g.colors[1], g.colors[2], (t - 0.333) * 3.0);
    } else {
        col = g.colors[2];
    }
    
    gl_FragColor = vec4(col, 1.0);
}
