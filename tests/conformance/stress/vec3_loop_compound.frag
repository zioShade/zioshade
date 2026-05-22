// Tests: compound assignment to vec3 component via subscript in loop
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 6; i++) {
        float angle = float(i) * 1.047 + uv.x * 6.28; // i * PI/3
        vec2 dir = vec2(cos(angle), sin(angle));
        float d = dot(uv - 0.5, dir);
        
        // Compound assignment to individual components
        col.r += smoothstep(0.0, 0.02, abs(d)) * 0.15;
        col.g += smoothstep(0.0, 0.01, abs(d)) * 0.1;
        col.b += smoothstep(0.0, 0.03, abs(d)) * 0.12;
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
