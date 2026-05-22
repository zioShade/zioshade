// Tests: vec4 swizzle read from function return, then conditional write
precision mediump float;
uniform vec2 u_resolution;

vec4 compute(float x, float y) {
    return vec4(x * y, x + y, x - y, x / (y + 0.001));
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 v = compute(uv.x, uv.y);
    float a = v.x;
    float b = v.y;
    
    if (a > b) {
        v.z = a * 2.0;
    } else {
        v.w = b * 3.0;
    }
    
    gl_FragColor = clamp(v, 0.0, 1.0);
}
