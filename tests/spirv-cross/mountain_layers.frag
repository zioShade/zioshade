#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Mountain silhouette layers
    vec3 col = vec3(0.3, 0.4, 0.7); // sky
    
    // Far mountains (lighter)
    float h1 = 5.0 + sin(uv.x * 0.3) * 2.0 + cos(uv.x * 0.7 + 1.0) * 1.5;
    col = mix(col, vec3(0.5, 0.55, 0.65), step(h1, uv.y));
    
    // Mid mountains
    float h2 = 4.0 + sin(uv.x * 0.5 + 2.0) * 2.5 + cos(uv.x * 1.0) * 1.0;
    col = mix(col, vec3(0.3, 0.35, 0.4), step(h2, uv.y));
    
    // Near mountains (darkest)
    float h3 = 3.0 + sin(uv.x * 0.8 + 4.0) * 2.0 + sin(uv.x * 2.0) * 0.5;
    col = mix(col, vec3(0.1, 0.12, 0.15), step(h3, uv.y));
    
    // Foreground
    col = mix(col, vec3(0.05, 0.08, 0.05), step(7.0, uv.y));
    
    fragColor = vec4(col, 1.0);
}
