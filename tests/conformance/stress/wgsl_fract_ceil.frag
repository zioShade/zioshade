#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float f = fract(uv.x * 5.0);
    float c = ceil(uv.y * 3.0);
    float fl = floor(uv.y * 3.0);
    vec3 col = vec3(f / 5.0, c / 3.0, fl / 3.0);
    fragColor = vec4(col, 1.0);
}
