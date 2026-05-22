// Tests: multiple struct returns in chain with conditional selection
precision mediump float;
uniform vec2 u_resolution;

struct Result {
    float value;
    vec3 color;
};

Result step1(float x) {
    Result r;
    r.value = x * 2.0;
    r.color = vec3(1.0, 0.5, 0.2);
    return r;
}

Result step2(float x) {
    Result r;
    r.value = x + 0.3;
    r.color = vec3(0.2, 0.5, 1.0);
    return r;
}

Result step3(float x) {
    Result r;
    r.value = fract(x);
    r.color = vec3(0.5, 1.0, 0.2);
    return r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Result a = step1(uv.x);
    Result b = step2(uv.y);
    Result c = step3(uv.x + uv.y);
    
    Result selected;
    if (uv.x > 0.66) {
        selected = a;
    } else if (uv.x > 0.33) {
        selected = b;
    } else {
        selected = c;
    }
    
    gl_FragColor = vec4(selected.color * selected.value, 1.0);
}
