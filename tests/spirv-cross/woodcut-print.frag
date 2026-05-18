#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test woodcut/linocut print pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 10.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    float h = hash(id);
    
    // Wood grain background
    float grain = sin((fp.y + h * 3.0) * 8.0 + sin(fp.x * 2.0) * 1.5);
    grain = grain * 0.5 + 0.5;
    
    // Carved lines forming a simple shape
    vec2 center = vec2(0.5);
    float d = length(fp - center);
    
    // Concentric carved rings
    float rings = sin(d * 25.0) * 0.5 + 0.5;
    
    // Radial carved lines
    float a = atan(fp.y - 0.5, fp.x - 0.5);
    float radial = sin(a * 8.0) * 0.5 + 0.5;
    
    // Combine: rings inside shape, radial outside
    float in_shape = smoothstep(0.35, 0.33, d);
    float carved = mix(radial, rings, in_shape);
    
    // Ink on paper: black carved lines on cream paper
    float ink = smoothstep(0.45, 0.5, carved);
    
    vec3 paper = vec3(0.92, 0.88, 0.82);
    vec3 ink_col = vec3(0.08, 0.06, 0.05);
    
    vec3 col = mix(paper, ink_col, ink);
    // Subtle wood texture on paper
    col *= 0.95 + grain * 0.05;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
