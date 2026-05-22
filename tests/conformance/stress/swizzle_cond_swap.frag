// Tests: self-referencing swizzle write (col.xy = col.yx) + conditional swizzle write
// This pattern previously triggered a branchMergePhi bug where the OpVariable
// was eliminated while AccessChains still referenced it.
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(0.0);
    col.x = uv.x;
    col.y = uv.y;
    col.xy = col.yx;  // self-referencing swizzle swap
    
    if (uv.x > 0.5) {
        col.zw = vec2(0.8, 0.9);
    }
    
    gl_FragColor = col;
}
