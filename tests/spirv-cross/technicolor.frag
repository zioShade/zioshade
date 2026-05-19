#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(0.0);
    col.r = sin(uv.x * 5.0 + 0.0) * 0.5 + 0.5;
    col.g = sin(uv.y * 5.0 + 2.09) * 0.5 + 0.5;
    col.b = sin((uv.x + uv.y) * 5.0 + 4.19) * 0.5 + 0.5;
    gl_FragColor = vec4(col, 1.0);
}
