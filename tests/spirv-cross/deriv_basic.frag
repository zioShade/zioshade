#version 450

// Test: FWidth and derivatives
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float dx = dFdx(uv.x);
    float dy = dFdy(uv.y);
    float fw = fwidth(uv.x + uv.y);

    vec3 col = vec3(dx * 128.0, dy * 128.0, fw * 128.0);
    gl_FragColor = vec4(col, 1.0);
}
