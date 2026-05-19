#version 450

// Test: vector shuffle with all components
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec4 a = vec4(uv.x, uv.y, 1.0 - uv.x, 1.0 - uv.y);

    vec4 b = a.wxyz;  // rotate right
    vec4 c = a.zwxy;  // swap halves
    vec4 d = a.yxwz;  // swap pairs

    gl_FragColor = (b + c + d) / 3.0;
}
