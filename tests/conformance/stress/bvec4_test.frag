// Tests: bvec4 construction and component access
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Construct bvec4 from comparisons
    bvec4 flags = bvec4(
        uv.x > 0.25,
        uv.x > 0.5,
        uv.y > 0.25,
        uv.y > 0.5
    );
    
    // Use bvec4 in calculations
    float r = flags.x ? 0.8 : 0.2;
    float g = flags.y ? 0.6 : 0.4;
    float b = flags.z ? 0.9 : 0.1;
    float a = flags.w ? 1.0 : 0.5;
    
    gl_FragColor = vec4(r, g, b, a);
}
