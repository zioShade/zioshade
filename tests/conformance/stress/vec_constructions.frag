// Tests: multiple vec2/vec3/vec4 construction patterns
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // vec4 from various components
    float a = uv.x;
    vec2 b = uv.yx;
    vec3 c = vec3(a, b);         // scalar + vec2 → vec3
    vec4 d = vec4(c, 1.0);       // vec3 + scalar → vec4
    
    // vec3 from scalar + scalar + scalar
    vec3 e = vec3(a, a, a);
    
    // vec4 from vec2 + vec2
    vec4 f = vec4(uv, uv.yx);    // vec2 + vec2 → vec4
    
    // Swizzle assignment
    vec4 g = vec4(0.0);
    g.xy = uv;
    g.zw = uv.yx;
    
    // Chained swizzle
    vec3 h = g.xyz * 2.0;
    
    vec3 col = mix(d.rgb, h, 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
