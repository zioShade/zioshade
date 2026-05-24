// Tests: nested structs with member functions pattern
#version 450
uniform vec2 u_resolution;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

float calcLight(Light l, vec3 pos) {
    float d = distance(l.pos, pos);
    return l.intensity / (1.0 + d * d);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    Light l;
    l.pos = vec3(0.5, 0.5, 0.0);
    l.color = vec3(1.0, 0.8, 0.6);
    l.intensity = 2.0;
    float brightness = calcLight(l, vec3(uv, 0.0));
    vec3 col = l.color * brightness;
    gl_FragColor = vec4(col, 1.0);
}
