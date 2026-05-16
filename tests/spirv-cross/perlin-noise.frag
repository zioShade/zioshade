#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// 2D Perlin-style noise gradient
void main() {
    vec2 p = uv * 4.0;
    
    float noise_val = 0.0;
    float amp = 1.0;
    float total_amp = 0.0;
    
    for (int i = 0; i < 4; i++) {
        vec2 ip = floor(p);
        vec2 fp = fract(p);
        fp = fp * fp * (3.0 - 2.0 * fp);
        
        float a = fract(sin(dot(ip, vec2(127.1, 311.7))) * 43758.5);
        float b = fract(sin(dot(ip + vec2(1, 0), vec2(127.1, 311.7))) * 43758.5);
        float c = fract(sin(dot(ip + vec2(0, 1), vec2(127.1, 311.7))) * 43758.5);
        float d = fract(sin(dot(ip + vec2(1, 1), vec2(127.1, 311.7))) * 43758.5);
        
        noise_val += mix(mix(a, b, fp.x), mix(c, d, fp.x), fp.y) * amp;
        total_amp += amp;
        amp *= 0.5;
        p *= 2.0;
    }
    
    noise_val /= total_amp;
    
    vec3 col = vec3(noise_val);
    fragColor = vec4(col, 1.0);
}
