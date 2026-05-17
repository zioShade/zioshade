#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested struct with array member
struct Hit {
    float t;
    int id;
};

struct Scene {
    Hit hits[3];
    float ambient;
};

void main() {
    Scene s;
    s.hits[0].t = 0.5;
    s.hits[0].id = 0;
    s.hits[1].t = 0.8;
    s.hits[1].id = 1;
    s.hits[2].t = 0.3;
    s.hits[2].id = 2;
    s.ambient = 0.1;
    
    // Find closest hit
    float min_t = s.hits[0].t;
    int min_id = s.hits[0].id;
    
    if (s.hits[1].t < min_t) { min_t = s.hits[1].t; min_id = s.hits[1].id; }
    if (s.hits[2].t < min_t) { min_t = s.hits[2].t; min_id = s.hits[2].id; }
    
    float r = float(min_id) / 3.0;
    float g = min_t;
    float b = s.ambient;
    
    fragColor = vec4(clamp(vec3(r, g, b), 0.0, 1.0), 1.0);
}
