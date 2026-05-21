#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    
    vec3 col = vec3(0.02);
    // Nested ternary with function calls
    col = r < 0.3 ? vec3(1.0, 0.8, 0.5) :
          r < 0.6 ? mix(vec3(0.5, 0.2, 0.1), vec3(0.2, 0.5, 0.8), (r - 0.3) / 0.3) :
          r < 0.9 ? vec3(0.1, 0.2, 0.4) * (1.0 - (r - 0.6) / 0.3) :
          vec3(0.02);
    // Add angular variation
    col += vec3(sin(a * 3.0) * 0.05, cos(a * 5.0) * 0.05, sin(a * 7.0) * 0.05);
    fragColor = vec4(max(col, vec3(0.0)), 1.0);
}
