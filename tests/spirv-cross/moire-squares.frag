#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test moire pattern from overlapping square grids
void main() {
    float s1 = sin(uv.x * 80.0) * sin(uv.y * 80.0);
    float s2 = sin(uv.x * 80.0 + 0.5) * sin(uv.y * 80.0 + 0.3);
    float s3 = sin((uv.x + uv.y) * 60.0);
    
    float moire = s1 * s2 + s3 * 0.3;
    moire = moire * 0.5 + 0.5;
    
    vec3 col = vec3(moire, moire * 0.8, moire * 0.6);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
