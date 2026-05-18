#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dithering patterns
void main() {
    float gray = uv.x;
    
    // Ordered dithering (Bayer 4x4)
    int bayer[16];
    bayer[0] = 0;  bayer[1] = 8;  bayer[2] = 2;  bayer[3] = 10;
    bayer[4] = 12; bayer[5] = 4;  bayer[6] = 14; bayer[7] = 6;
    bayer[8] = 3;  bayer[9] = 11; bayer[10] = 1; bayer[11] = 9;
    bayer[12] = 15; bayer[13] = 7; bayer[14] = 13; bayer[15] = 5;
    
    int ix = int(mod(uv.x * 64.0, 4.0));
    int iy = int(mod(uv.y * 64.0, 4.0));
    int idx = iy * 4 + ix;
    float threshold = float(bayer[idx]) / 16.0;
    
    // Gradient with dithering
    float gradient = uv.y;
    float dithered = step(threshold, gradient);
    
    // Show gradient on left, dithered on right
    float split = step(0.5, uv.x);
    float val = mix(gradient, dithered, split);
    
    fragColor = vec4(vec3(val), 1.0);
}
