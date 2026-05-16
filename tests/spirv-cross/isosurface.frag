#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Dynamic branching: marching squares isosurface
void main() {
    vec2 p = uv * 5.0;
    vec2 ip = floor(p);
    vec2 fp = fract(p);
    
    float threshold = 0.5;
    
    // Corner values
    float c00 = fract(sin(dot(ip, vec2(127.1, 311.7))) * 43758.5);
    float c10 = fract(sin(dot(ip + vec2(1, 0), vec2(127.1, 311.7))) * 43758.5);
    float c01 = fract(sin(dot(ip + vec2(0, 1), vec2(127.1, 311.7))) * 43758.5);
    float c11 = fract(sin(dot(ip + vec2(1, 1), vec2(127.1, 311.7))) * 43758.5);
    
    // Bilinear interpolation
    float val = mix(mix(c00, c10, fp.x), mix(c01, c11, fp.x), fp.y);
    
    float contour = smoothstep(0.02, 0.0, abs(val - threshold));
    
    vec3 bg = vec3(0.1, 0.1, 0.2);
    vec3 line = vec3(0.3, 0.8, 0.5);
    vec3 col = mix(bg, line, contour);
    
    fragColor = vec4(col, 1.0);
}
