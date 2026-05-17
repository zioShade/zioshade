#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test integer loop with continue and break
void main() {
    float sum = 0.0;
    int count = 0;
    
    for (int i = 0; i < 20; i++) {
        if (i % 3 == 0) continue;  // Skip multiples of 3
        if (i > 15) break;         // Stop at 15
        
        sum += float(i) * 0.1;
        count++;
    }
    
    float avg = sum / float(count + 1);
    vec3 col = vec3(avg, sum * 0.2, float(count) / 20.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
