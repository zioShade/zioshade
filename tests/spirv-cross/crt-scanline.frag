#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test CRT scanline effect
void main() {
    // Base color from UV
    vec3 col = vec3(uv.x, uv.y, 0.3);
    
    // Scanlines
    float scanline = sin(uv.y * 400.0) * 0.5 + 0.5;
    scanline = mix(0.7, 1.0, scanline);
    
    // Phosphor grid (RGB subpixels)
    float sub_r = smoothstep(0.3, 0.5, fract(uv.x * 300.0));
    float sub_g = smoothstep(0.3, 0.5, fract(uv.x * 300.0 + 0.333));
    float sub_b = smoothstep(0.3, 0.5, fract(uv.x * 300.0 + 0.667));
    
    col.r *= sub_r * scanline;
    col.g *= sub_g * scanline;
    col.b *= sub_b * scanline;
    
    // Vignette
    float vig = 1.0 - length(uv - 0.5) * 0.8;
    col *= vig;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
