// Tests: complex expression combining many operators
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Chained math with mixed types
    float a = sin(uv.x * 12.0) * cos(uv.y * 8.0);
    float b = abs(a) * 2.0 - 1.0;
    float c = smoothstep(-0.5, 0.5, b);
    float d = mix(c, 1.0 - c, step(0.5, fract(uv.x * 3.0)));
    
    vec2 e = vec2(
        d + tan(uv.x * 0.5) * 0.1,
        d + asin(clamp(uv.y * 2.0 - 1.0, -1.0, 1.0)) * 0.1
    );
    
    float f = length(e);
    float g = atan(e.y, e.x) / 6.28 + 0.5;
    
    vec3 col = vec3(f, g, d);
    col = pow(col, vec3(0.8)); // gamma correction
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
