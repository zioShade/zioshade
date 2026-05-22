// Tests: vec4 swizzle write + conditional swizzle write
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = vec4(0.0);
    col.x = uv.x;
    col.y = uv.y;
    col.xy = col.yx;
    
    if (uv.x > 0.5) {
        col.zw = vec2(0.8, 0.9);
    }
    
    gl_FragColor = col;
}
