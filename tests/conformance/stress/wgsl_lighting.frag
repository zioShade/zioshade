// Test: multiple function calls with complex returns
#version 450

layout(location = 0) out vec4 fragColor;

struct Light {
    vec3 position;
    vec3 color;
    float intensity;
};

Light makeLight(vec3 pos, vec3 col, float inten) {
    Light l;
    l.position = pos;
    l.color = col;
    l.intensity = inten;
    return l;
}

float attenuate(Light l, float dist) {
    return l.intensity / (1.0 + dist * dist);
}

vec3 shade(Light l, vec3 normal, vec3 fragPos) {
    vec3 lightDir = normalize(l.position - fragPos);
    float diff = max(dot(normal, lightDir), 0.0);
    float att = attenuate(l, length(l.position - fragPos));
    return l.color * diff * att;
}

void main() {
    vec3 pos = vec3(gl_FragCoord.xy, 0.0);
    vec3 normal = normalize(vec3(0.0, 1.0, 0.0));
    
    Light l1 = makeLight(vec3(2.0, 3.0, 1.0), vec3(1.0, 0.9, 0.8), 2.0);
    Light l2 = makeLight(vec3(-1.0, 2.0, 3.0), vec3(0.5, 0.6, 1.0), 1.5);
    
    vec3 c1 = shade(l1, normal, pos);
    vec3 c2 = shade(l2, normal, pos);
    vec3 final = c1 + c2;
    
    fragColor = vec4(final, 1.0);
}
