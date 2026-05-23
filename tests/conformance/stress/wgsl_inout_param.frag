#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

// inout parameter — exercises pointer semantics in WGSL
void accumulate(inout vec3 col, float x) {
    col.r += x * 0.5;
    col.g += x * 0.3;
    col.b += x * 0.2;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 col = vec3(0.0);
    for (int i = 0; i < 5; i++) {
        accumulate(col, float(i) * uv.x * 0.1);
    }
    fragColor = vec4(col, 1.0);
}
