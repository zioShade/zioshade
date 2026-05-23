#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

// Struct with function return — exercises struct type resolution in WGSL
struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

Light makeLight(vec2 uv) {
    Light l;
    l.pos = vec3(uv, 0.5);
    l.color = vec3(1.0, 0.8, 0.6);
    l.intensity = length(uv);
    return l;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    Light l = makeLight(uv);
    vec3 col = l.color * l.intensity;
    fragColor = vec4(col, 1.0);
}
