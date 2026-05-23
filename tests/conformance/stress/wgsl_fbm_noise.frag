#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

// Recursive-like pattern using multiple function calls
float noise(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        val += amp * noise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float n = fbm(uv * 4.0);
    vec3 col = mix(vec3(0.1, 0.2, 0.5), vec3(0.9, 0.7, 0.3), n);
    fragColor = vec4(col, 1.0);
}
