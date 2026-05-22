// Tests: function overloading with different param types
precision mediump float;
uniform vec2 u_resolution;

float process(float x) {
    return x * 2.0;
}

vec2 process(vec2 v) {
    return v * 2.0;
}

vec3 process(vec3 v) {
    return v * 2.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float a = process(uv.x);
    vec2 b = process(uv);
    vec3 c = process(vec3(uv, 0.5));
    
    vec3 col = vec3(a, b.x, c.z);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
