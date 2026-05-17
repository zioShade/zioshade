#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Bayer matrix color pattern
void main() {
    // 4x4 Bayer matrix for ordered dithering
    int bayer[16];
    bayer[0] = 0;  bayer[1] = 8;  bayer[2] = 2;  bayer[3] = 10;
    bayer[4] = 12; bayer[5] = 4;  bayer[6] = 14; bayer[7] = 6;
    bayer[8] = 3;  bayer[9] = 11; bayer[10] = 1; bayer[11] = 9;
    bayer[12] = 15; bayer[13] = 7; bayer[14] = 13; bayer[15] = 5;
    
    int ix = int(mod(uv.x * 8.0, 4.0));
    int iy = int(mod(uv.y * 8.0, 4.0));
    int idx = iy * 4 + ix;
    
    float threshold = float(bayer[idx]) / 16.0;
    
    vec3 col1 = vec3(0.9, 0.3, 0.1);
    vec3 col2 = vec3(0.1, 0.3, 0.9);
    
    float t = uv.x;
    vec3 col = mix(col1, col2, step(threshold, t));
    
    fragColor = vec4(col, 1.0);
}
