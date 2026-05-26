// Test: complex function with inout params and recursion-like pattern
#version 450

layout(location = 0) out vec4 fragColor;

void accumulate(inout float total, inout int count, float val) {
    total += val;
    count += 1;
}

float average(float total, int count) {
    return count > 0 ? total / float(count) : 0.0;
}

void process(vec2 uv, inout float sum, inout int n) {
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float v = sin(uv.x * fi + uv.y * fi) * 0.5 + 0.5;
        accumulate(sum, n, v);
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float sum1 = 0.0;
    int count1 = 0;
    process(uv, sum1, count1);
    
    float avg = average(sum1, count1);
    
    fragColor = vec4(vec3(avg), 1.0);
}
