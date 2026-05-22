// Tests: discard with struct variable across conditional
precision mediump float;
uniform vec2 u_resolution;

struct Pixel {
    vec3 color;
    float alpha;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Pixel p;
    p.color = vec3(uv, 0.5);
    p.alpha = 1.0;
    
    if (length(uv - 0.5) > 0.4) {
        p.alpha = 0.0;
    }
    
    if (p.alpha < 0.5) {
        discard;
    }
    
    gl_FragColor = vec4(p.color, p.alpha);
}
