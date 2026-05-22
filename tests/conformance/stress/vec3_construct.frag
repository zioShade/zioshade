// Tests: vec3 construction with mixed scalar and vector args
// Previously broken: vec3(scalar, vec2) produced wrong component count
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // All vec3 construction variants
    vec3 a = vec3(uv.x, uv.y, 0.5);        // s, s, s
    vec3 b = vec3(uv, 0.5);                  // v2, s
    vec3 c = vec3(0.5, uv);                  // s, v2
    vec3 d = vec3(uv.xyx);                   // swizzle
    vec3 e = vec3(0.0);                      // single scalar
    
    vec3 col = a * 0.2 + b * 0.2 + c * 0.2 + d * 0.2 + e * 0.2;
    gl_FragColor = vec4(col, 1.0);
}
