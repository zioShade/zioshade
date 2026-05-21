#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    
    // Ternary with same variable in both branches
    vec3 sky = vec3(0.4, 0.6, 0.9);
    vec3 water = vec3(0.1, 0.3, 0.6);
    vec3 col = r < 0.5 ? sky * (1.0 - r * 2.0) : water * (1.0 - r);
    col += vec3(0.05) * sin(a * 8.0);
    fragColor = vec4(col, 1.0);
}
