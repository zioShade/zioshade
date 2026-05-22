// Tests: complex expression in vector construction with function calls
precision mediump float;
uniform vec2 u_resolution;

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Complex expressions inside vector construction
    vec3 col = vec3(
        hash(uv.x * 100.0) * 0.5 + 0.25,
        mix(hash(uv.x * 50.0), hash(uv.y * 50.0), 0.5),
        step(0.5, uv.y) * hash(uv.x * 200.0)
    );
    
    gl_FragColor = vec4(col, 1.0);
}
