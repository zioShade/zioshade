// Test: triple-nested loop with break and continue
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float sum = 0.0;
    int count = 0;
    
    for (int z = 0; z < 4; z++) {
        for (int y = 0; y < 4; y++) {
            for (int x = 0; x < 4; x++) {
                float fx = float(x) / 4.0;
                float fy = float(y) / 4.0;
                float fz = float(z) / 4.0;
                
                float d = length(vec3(fx - uv.x, fy - uv.y, fz - 0.5));
                
                if (d > 0.5) continue;
                if (d < 0.01) continue;
                
                sum += 1.0 / d;
                count++;
                
                if (count > 20) break;
            }
            if (count > 20) break;
        }
        if (count > 20) break;
    }
    
    fragColor = vec4(sum * 0.1, float(count) / 20.0, 0.0, 1.0);
}
