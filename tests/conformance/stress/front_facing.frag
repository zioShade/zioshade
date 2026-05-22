// Tests: gl_HelperInvocation and gl_FrontFacing builtins
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // gl_FrontFacing is always available for fragment shaders
    float facing = gl_FrontFacing ? 1.0 : 0.5;
    
    vec3 col = vec3(uv * facing, facing * 0.5);
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
