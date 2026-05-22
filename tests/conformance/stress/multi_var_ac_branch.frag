// Tests: multiple variables with AccessChains across conditional branches
// Exercises: branchMergePhi disqualification for variables with AccessChains
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 a = vec4(0.0);
    a.x = 0.3;
    a.y = uv.y;
    
    vec4 b = vec4(1.0);
    b.x = uv.x;
    b.y = 0.7;
    
    if (uv.x > 0.5) {
        a.z = 1.0;
        b.z = 0.5;
    } else {
        a.w = 1.0;
        b.w = 0.5;
    }
    
    vec4 col = a + b * 0.5;
    gl_FragColor = clamp(col, 0.0, 1.0);
}
