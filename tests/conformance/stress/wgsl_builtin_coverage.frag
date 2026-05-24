// Tests: GLSL built-in functions coverage
#version 450
uniform vec2 u_resolution;
uniform float u_time;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Mix and step
    float a = mix(0.0, 1.0, uv.x);
    float b = step(0.5, uv.y);
    
    // Smoothstep
    float c = smoothstep(0.3, 0.7, uv.x);
    
    // Clamp and saturate-like
    float d = clamp(u_time, 0.0, 1.0);
    
    // Min/max
    float e = min(uv.x, uv.y);
    float f = max(uv.x, uv.y);
    
    gl_FragColor = vec4(a * b + c * 0.3 + d * 0.1, e, f, 1.0);
}
