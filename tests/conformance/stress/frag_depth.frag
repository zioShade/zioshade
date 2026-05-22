// Tests: gl_FragDepth output with conditional write
#version 440
out vec4 fragColor;
in vec4 gl_FragCoord;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec3 col = vec3(uv, 0.5);
    
    // Write gl_FragDepth conditionally
    if (uv.x > 0.5) {
        gl_FragDepth = 0.25;
    } else {
        gl_FragDepth = 0.75;
    }
    
    fragColor = vec4(col, 1.0);
}
