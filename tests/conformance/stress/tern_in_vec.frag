// Tests: nested ternary in vector construction
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a = uv.x > 0.5 ? (uv.y > 0.5 ? 1.0 : 0.5) : 0.0;
    float b = uv.x < 0.25 ? 0.8 : (uv.x < 0.75 ? 0.4 : 0.2);
    float c = uv.y > 0.5 ? sin(uv.x * 6.28) : cos(uv.y * 6.28);
    
    // Ternary as part of vector constructor
    vec3 col = vec3(
        uv.x > 0.3 ? a : b,
        uv.y > 0.7 ? b : c,
        c > 0.0 ? a * 2.0 : b * 0.5
    );
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
