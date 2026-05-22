// Tests: local array of structs with conditional element modification
precision mediump float;
uniform vec2 u_resolution;

struct Light {
    vec3 color;
    float intensity;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Light lights[3];
    lights[0].color = vec3(1.0, 0.0, 0.0);
    lights[0].intensity = 0.8;
    lights[1].color = vec3(0.0, 1.0, 0.0);
    lights[1].intensity = 0.6;
    lights[2].color = vec3(0.0, 0.0, 1.0);
    lights[2].intensity = 0.4;
    
    // Conditional modification
    if (uv.x > 0.5) {
        lights[0].intensity *= 2.0;
    }
    
    int idx = int(uv.y * 2.999);
    idx = clamp(idx, 0, 2);
    
    vec3 col = lights[idx].color * lights[idx].intensity;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
