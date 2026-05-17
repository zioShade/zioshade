#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test recursive-pattern noise with offset
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 5.0;
    float n = 0.0;
    float amp = 0.5;
    
    for (int i = 0; i < 4; i++) {
        vec2 ip = floor(p);
        vec2 fp = fract(p);
        fp = fp * fp * (3.0 - 2.0 * fp);
        
        n += mix(
            mix(hash(ip), hash(ip + vec2(1, 0)), fp.x),
            mix(hash(ip + vec2(0, 1)), hash(ip + vec2(1, 1)), fp.x),
            fp.y
        ) * amp;
        
        // Rotate and scale
        float angle = float(i) * 0.785;
        float c = cos(angle);
        float s = sin(angle);
        p = vec2(c * p.x - s * p.y, s * p.x + c * p.y) * 2.0;
        amp *= 0.5;
    }
    
    vec3 col = vec3(n, n * 0.7, n * 0.4);
    fragColor = vec4(col, 1.0);
}
