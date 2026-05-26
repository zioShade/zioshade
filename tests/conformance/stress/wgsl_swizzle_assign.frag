// Test: vec4 swizzle reassignment patterns
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec4 color = vec4(0.0);
    color.x = uv.x;
    color.y = uv.y;
    color.z = (uv.x + uv.y) * 0.5;
    color.w = 1.0;
    
    vec4 other = color;
    other.xy = color.yx;  // Swap x and y
    other.zw = vec2(0.5, 0.7);
    
    vec4 combined = color + other;
    combined.xyz *= 0.5;
    
    fragColor = combined;
}
