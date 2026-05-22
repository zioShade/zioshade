// Tests: mat3 subscript assignment in conditional branch
// Previously broken: analyzeLValue missing matrix case
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    
    mat3 m = mat3(1.0);
    m[0] = vec3(c, s, 0.0);
    m[1] = vec3(-s, c, 0.0);
    
    if (uv.y > 0.5) {
        m[2] = vec3(0.0, 0.0, 2.0);
    }
    
    vec3 p = m * vec3(uv, 1.0);
    
    gl_FragColor = vec4(fract(p.x), fract(p.y), fract(p.z), 1.0);
}
