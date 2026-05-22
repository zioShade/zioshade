// Tests: vec4 construction with mixed scalar/vector args
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 v3 = vec3(uv, 0.0);
    
    // All vec4 construction variants
    vec4 a = vec4(v3, 1.0);               // v3, s
    vec4 b = vec4(1.0, v3);               // s, v3
    vec4 c = vec4(uv, uv.yx);             // v2, v2
    vec4 d = vec4(0.0);                   // single scalar
    vec4 e = vec4(v3.xyy + uv.xyx);       // swizzle math
    
    vec4 col = a * 0.25 + b * 0.25 + c * 0.25 + d * 0.25;
    gl_FragColor = clamp(col, 0.0, 1.0);
}
