// Tests: function with 3 struct params and 1 inout param
precision mediump float;
uniform vec2 u_resolution;

struct Ray { vec2 origin; vec2 dir; };
struct Hit { float t; int id; };
struct Material { vec3 albedo; float roughness; };

vec3 shade(Ray r, Hit h, Material m, inout vec3 acc) {
    vec2 p = r.origin + r.dir * h.t;
    float d = length(p);
    vec3 contribution = m.albedo * (1.0 / (d + 0.1)) * (1.0 - m.roughness);
    acc += contribution;
    return acc;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Ray r;
    r.origin = vec2(0.0);
    r.dir = normalize(uv - 0.5);
    
    Hit h;
    h.t = length(uv);
    h.id = 0;
    
    Material m;
    m.albedo = vec3(0.8, 0.4, 0.2);
    m.roughness = 0.3;
    
    vec3 acc = vec3(0.0);
    vec3 result = shade(r, h, m, acc);
    
    gl_FragColor = vec4(clamp(result, 0.0, 1.0), 1.0);
}
