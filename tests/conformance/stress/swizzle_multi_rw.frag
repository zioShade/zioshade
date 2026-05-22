// Tests: multiple swizzle writes and reads
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 a = vec4(0.0);
    a.xy = uv;
    a.w = 1.0;
    
    vec4 b = vec4(0.5);
    b.xz = a.yx;
    
    if (uv.y > 0.5) {
        b.yw = a.xz;
    }
    
    vec4 c = a + b;
    gl_FragColor = clamp(c, 0.0, 1.0);
}
