// Tests: uniform buffer with multiple members
#version 450
layout(binding = 0) uniform Params {
    float u_time;
    vec2 u_resolution;
    float u_scale;
    int u_count;
};

void main() {
    float aspect = u_resolution.x / u_resolution.y;
    float scaled = u_time * u_scale;
    float count_f = float(u_count);
    gl_FragColor = vec4(scaled, aspect, count_f, 1.0);
}
