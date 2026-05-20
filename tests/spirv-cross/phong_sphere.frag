#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // 3D sphere with Phong shading
    vec3 light_dir = normalize(vec3(1.0, 1.0, -1.0));
    float r = length(uv);
    if (r < 1.0) {
        float z = sqrt(1.0 - r * r);
        vec3 normal = vec3(uv, z);
        float diffuse = max(dot(normal, light_dir), 0.0);
        vec3 view_dir = vec3(0.0, 0.0, 1.0);
        vec3 half_vec = normalize(light_dir + view_dir);
        float specular = pow(max(dot(normal, half_vec), 0.0), 32.0);
        vec3 base = vec3(0.2, 0.4, 0.8);
        vec3 col = base * (0.1 + 0.7 * diffuse) + vec3(1.0) * specular * 0.5;
        fragColor = vec4(col, 1.0);
    } else {
        fragColor = vec4(0.1, 0.1, 0.15, 1.0);
    }
}
