// Test: LUT (look-up table) via uniform array
#version 450

layout(binding = 0) uniform LUT {
    vec4 colors[8];
};

layout(location = 0) out vec4 fragColor;

void main() {
    float val = gl_FragCoord.x / 800.0;
    
    int idx = int(val * 8.0);
    idx = min(idx, 7);
    
    vec4 c = colors[idx];
    float frac = fract(val * 8.0);
    int next = min(idx + 1, 7);
    vec4 c2 = colors[next];
    
    vec4 result = mix(c, c2, frac);
    fragColor = result;
}
