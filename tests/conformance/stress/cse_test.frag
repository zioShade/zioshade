// Tests: repeated identical expressions (CSE opportunity)
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Same expression computed multiple times
    float d1 = length(uv - vec2(0.3, 0.5));
    float d2 = length(uv - vec2(0.3, 0.5)); // identical to d1
    float d3 = length(uv - vec2(0.7, 0.5));
    
    // Use all results to prevent DCE
    float ring1 = abs(d1 - 0.2);
    float ring2 = smoothstep(0.01, 0.02, d2);
    float ring3 = smoothstep(0.01, 0.02, d3);
    
    float result = min(ring1, min(ring2, ring3));
    
    vec3 col = vec3(result, d1, d3);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
