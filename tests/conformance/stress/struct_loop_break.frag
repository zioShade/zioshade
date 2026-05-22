// Tests: for-loop with break, continue, and struct variable
precision mediump float;
uniform vec2 u_resolution;

struct Accum {
    float sum;
    float count;
};

Accum accumulate(Accum a, float val) {
    a.sum += val;
    a.count += 1.0;
    return a;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Accum acc;
    acc.sum = 0.0;
    acc.count = 0.0;
    
    for (int i = 0; i < 10; i++) {
        float x = float(i) / 10.0;
        if (x < uv.x - 0.1) continue;
        if (x > uv.x + 0.3) break;
        acc = accumulate(acc, x * x);
    }
    
    float avg = acc.sum / (acc.count + 0.001);
    vec3 col = vec3(avg, acc.sum * 0.1, acc.count * 0.1);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
