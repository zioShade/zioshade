// Test: loop with conditional continue and accumulation
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float positive_sum = 0.0;
    float negative_sum = 0.0;
    int count = 0;
    
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float val = sin(fi * 1.5 + uv.x * 6.28) * cos(fi * 0.7 + uv.y * 6.28);
        
        // Skip near-zero values
        if (abs(val) < 0.05) continue;
        
        if (val > 0.0) {
            positive_sum += val;
        } else {
            negative_sum += val;
        }
        count++;
    }
    
    fragColor = vec4(positive_sum * 0.5, abs(negative_sum) * 0.5, float(count) / 20.0, 1.0);
}
