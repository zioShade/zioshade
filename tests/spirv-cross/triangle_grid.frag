#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 5.0;
    vec2 row = vec2(uv.x + floor(uv.y) * 0.5, uv.y);
    float tri = fract(row.x) + fract(row.y);
    float col = step(0.5, tri);
    gl_FragColor = vec4(col, col * 0.6, col * 0.3, 1.0);
}
