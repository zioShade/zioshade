#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Flower / petal pattern
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float angle = atan(p.y, p.x);
    
    // Petal function
    float petals = 5.0;
    float petal = cos(angle * petals) * 0.5 + 0.5;
    float flower_shape = petal * 0.4;
    
    float inside = smoothstep(flower_shape + 0.02, flower_shape - 0.02, r);
    
    // Center
    float center = smoothstep(0.1, 0.05, r);
    
    vec3 petal_col = vec3(0.9, 0.3, 0.5);
    vec3 center_col = vec3(1.0, 0.8, 0.2);
    vec3 bg_col = vec3(0.1, 0.3, 0.1);
    
    vec3 col = bg_col;
    col = mix(col, petal_col, inside);
    col = mix(col, center_col, center);
    
    fragColor = vec4(col, 1.0);
}
