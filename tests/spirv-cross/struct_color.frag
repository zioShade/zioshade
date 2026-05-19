#version 450

// Test: function returning struct, accessed multiple times
struct ColorResult {
    vec3 diffuse;
    vec3 specular;
    float alpha;
};

ColorResult computeColor(vec3 base, vec3 light, float intensity) {
    ColorResult r;
    r.diffuse = base * light * intensity;
    r.specular = pow(max(dot(light, vec3(0.0, 0.0, 1.0)), 0.0), 32.0) * light;
    r.alpha = intensity;
    return r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 base = vec3(0.8, 0.4, 0.2);
    vec3 light = normalize(vec3(uv, 1.0));
    ColorResult c = computeColor(base, light, 0.8);
    gl_FragColor = vec4(c.diffuse + c.specular, c.alpha);
}
