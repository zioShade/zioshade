#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy;
    vec2 p = uv * 0.02;
    
    // Warp pattern using loops
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        p.x += sin(p.y * fi + fi) * 0.5;
        p.y += cos(p.x * fi + fi) * 0.5;
    }
    
    vec3 col = vec3(sin(p.x * 3.0) * 0.5 + 0.5,
                    sin(p.y * 3.0) * 0.5 + 0.5,
                    sin((p.x + p.y) * 2.0) * 0.5 + 0.5);
    fragColor = vec4(col, 1.0);
}
