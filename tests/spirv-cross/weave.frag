#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 8.0;
    vec2 f = fract(uv);
    float horiz = step(f.y, f.x);
    float vert = step(f.x, f.y);
    vec3 colH = vec3(0.7, 0.3, 0.2) * horiz;
    vec3 colV = vec3(0.2, 0.3, 0.7) * vert;
    gl_FragColor = vec4(colH + colV, 1.0);
}
