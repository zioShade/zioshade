#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 p = uv * 8.0;
    
    float h = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        h += sin(p.x * (0.5 + fi * 0.1) + iTime * (1.0 + fi * 0.2)) * 0.5 / (1.0 + fi);
        h += sin(p.y * (0.3 + fi * 0.15) + iTime * (0.8 + fi * 0.1)) * 0.5 / (1.0 + fi);
    }
    
    // Fake normal from height
    float dx = h - sin((p.x + 0.01) * 0.5 + iTime) * 0.5;
    float dy = h - sin((p.y + 0.01) * 0.3 + iTime * 0.8) * 0.5;
    vec3 n = normalize(vec3(dx, dy, 0.02));
    
    vec3 light = normalize(vec3(1.0, 1.0, 0.5));
    float diff = max(dot(n, light), 0.0);
    float spec = pow(max(dot(reflect(-light, n), vec3(0.0, 0.0, 1.0)), 0.0), 32.0);
    
    vec3 col = vec3(0.0, 0.2, 0.4) + vec3(0.1, 0.3, 0.5) * diff + vec3(1.0) * spec * 0.5;
    fragColor = vec4(col, 1.0);
}
