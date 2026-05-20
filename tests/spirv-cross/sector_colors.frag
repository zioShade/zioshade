#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Nested ternary chain for color bands
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float sector = floor((a + 3.14159) / 0.6283);
    vec3 col = sector < 1.0 ? vec3(1.0, 0.2, 0.2) :
               sector < 2.0 ? vec3(1.0, 0.6, 0.1) :
               sector < 3.0 ? vec3(1.0, 1.0, 0.2) :
               sector < 4.0 ? vec3(0.2, 0.9, 0.2) :
               sector < 5.0 ? vec3(0.1, 0.5, 1.0) :
               sector < 6.0 ? vec3(0.4, 0.2, 0.8) :
               sector < 7.0 ? vec3(0.8, 0.2, 0.6) :
               sector < 8.0 ? vec3(0.6, 0.4, 0.2) :
               sector < 9.0 ? vec3(0.3, 0.8, 0.7) :
               vec3(0.9, 0.5, 0.4);
    col *= smoothstep(1.0, 0.8, r) * smoothstep(0.0, 0.1, r);
    fragColor = vec4(col, 1.0);
}
