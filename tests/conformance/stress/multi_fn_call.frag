// Tests: calling same function multiple times with different args in one expression
precision mediump float;
uniform vec2 u_resolution;

float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Multiple calls in one expression
    float n = noise(uv) * 0.5 + noise(uv * 2.0) * 0.25 + noise(uv * 4.0) * 0.125;
    
    // Another chain
    float m = mix(noise(uv + 0.5), noise(uv + 1.0), noise(uv + 1.5));
    
    float result = n + m * 0.5;
    
    gl_FragColor = vec4(vec3(fract(result)), 1.0);
}
