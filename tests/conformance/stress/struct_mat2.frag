// Tests: struct with mat2 member, conditional modification
precision mediump float;
uniform vec2 u_resolution;

struct Transform2D {
    mat2 rotation;
    vec2 translation;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Transform2D t;
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    t.rotation = mat2(c, -s, s, c);
    t.translation = vec2(0.5);
    
    if (uv.y > 0.5) {
        t.rotation = mat2(1.0);
        t.translation = uv;
    }
    
    vec2 p = t.rotation * (uv - 0.5) + t.translation;
    
    gl_FragColor = vec4(fract(p.x), fract(p.y), 0.5, 1.0);
}
