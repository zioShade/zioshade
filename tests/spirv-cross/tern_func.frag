#version 310 es
precision highp float;
out vec4 fragColor;

float helper(float x) { return x * x + 0.1; }

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    vec3 col = r < 0.5 
        ? vec3(helper(uv.x), helper(uv.y), 0.5) 
        : vec3(0.1, helper(r), helper(1.0 - r));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
