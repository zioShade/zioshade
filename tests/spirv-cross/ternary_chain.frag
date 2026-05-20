#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Complex ternary chain
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    vec3 col = r < 0.2 ? vec3(1.0, 0.0, 0.0) :
               r < 0.4 ? vec3(1.0, 0.5, 0.0) :
               r < 0.6 ? vec3(1.0, 1.0, 0.0) :
               r < 0.8 ? vec3(0.0, 1.0, 0.0) :
               vec3(0.0, 0.0, 1.0);
    // Mix with angle-based pattern
    col *= 0.7 + 0.3 * sin(a * 3.0);
    fragColor = vec4(col, 1.0);
}
