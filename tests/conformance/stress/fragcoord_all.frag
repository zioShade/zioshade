// Tests: gl_FragCoord usage with swizzle and arithmetic
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    float z = gl_FragCoord.z;
    float w = gl_FragCoord.w;
    
    // Use all components
    float r = fract(x / u_resolution.x);
    float g = fract(y / u_resolution.y);
    float b = z * 0.5;
    float a = 1.0 / (w + 1.0);
    
    gl_FragColor = vec4(r, g, b, a);
}
