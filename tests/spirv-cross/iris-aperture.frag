#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test camera iris aperture blades
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    float blades = 6.0;
    
    // Polygon distance
    float angle_to_edge = 3.14159 / blades;
    float sector = mod(a + angle_to_edge, 2.0 * angle_to_edge) - angle_to_edge;
    float max_r = 0.3 / cos(sector);
    
    float iris = smoothstep(max_r - 0.01, max_r, r);
    
    // Scene behind iris (gradient)
    vec3 scene = vec3(uv.x, uv.y, 0.5);
    
    // Iris blade color
    float blade_shade = 0.3 + sector * 0.2;
    vec3 iris_col = vec3(blade_shade);
    
    // Edge highlight
    float edge = smoothstep(0.02, 0.0, abs(r - max_r));
    
    vec3 col = mix(scene, iris_col, iris) + edge * vec3(0.5);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
