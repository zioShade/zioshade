#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 5.0;
    float col_idx = floor(x);
    float drip = sin(col_idx * 2.3 + uv.y * 10.0) * 0.5 + 0.5;
    vec3 col = vec3(fract(col_idx * 0.3), fract(col_idx * 0.5), fract(col_idx * 0.7)) * drip;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
