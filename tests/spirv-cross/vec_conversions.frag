#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // Type conversion chains
    float f = gl_FragCoord.x;
    int i = int(f);
    uint u = uint(f);
    bool b = f > 100.0;
    
    // Back to float
    float f2 = float(i);
    float f3 = float(u);
    float f4 = float(b);
    
    // Vec conversions
    vec4 fv = vec4(1.5, 2.5, 3.5, 4.5);
    ivec4 iv = ivec4(fv);
    uvec4 uv = uvec4(fv);
    bvec4 bv = bvec4(fv);
    
    vec4 back = vec4(iv);
    float r = f2 / 255.0;
    float g = f3 / 255.0;
    float bl = f4;
    fragColor = vec4(r, g, bl, back.x / 4.0);
}
