// Tests: vec2 swizzle assignment to vec3 components
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec3 a = vec3(0.0);
    a.xy = uv;              // vec2 swizzle write to vec3
    a.z = length(uv);
    
    vec3 b = vec3(1.0);
    b.yz = uv.yx;           // reversed swizzle write
    
    vec3 c = a + b * 0.5;
    gl_FragColor = vec4(c, 1.0);
}
