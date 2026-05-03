#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec2 z = uv * 2.0;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        // Vortex transform
        float r = length(z);
        float a = atan(z.y, z.x);
        a += sin(r * 3.0 - iTime) * 0.5;
        z = vec2(cos(a), sin(a)) * r;
        
        // Fold
        z = abs(z);
        z = z * 1.5 - vec2(1.0, 0.5);
        
        // Accumulate color
        float d = length(z);
        col += vec3(
            0.5 + 0.5 * sin(fi * 0.3 + iTime),
            0.5 + 0.5 * sin(fi * 0.3 + iTime + 2.0),
            0.5 + 0.5 * sin(fi * 0.3 + iTime + 4.0)
        ) * 0.05 / (d + 0.1);
    }
    
    col = clamp(col, 0.0, 1.0);
    fragColor = vec4(col, 1.0);
}
