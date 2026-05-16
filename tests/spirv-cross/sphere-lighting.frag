#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Drop shadow on circle
    vec2 p = uv - 0.5;

    // Shadow offset
    vec2 shadow_p = p - vec2(0.03, -0.03);
    float shadow = 1.0 - smoothstep(0.28, 0.32, length(shadow_p));

    // Circle
    float circle = 1.0 - smoothstep(0.28, 0.30, length(p));

    // Light direction
    vec3 light_dir = normalize(vec3(0.5, 0.5, 1.0));
    vec3 normal = vec3(p, sqrt(max(0.0, 0.09 - p.x * p.x - p.y * p.y)));
    normal = normalize(normal);

    float diffuse = max(dot(normal, light_dir), 0.0);
    float specular = pow(max(dot(reflect(-light_dir, normal), vec3(0.0, 0.0, 1.0)), 0.0), 32.0);

    vec3 col = vec3(0.0);
    col += vec3(0.2, 0.2, 0.25) * shadow;  // shadow
    col += vec3(0.6, 0.3, 0.2) * circle * diffuse;  // diffuse
    col += vec3(1.0, 0.9, 0.8) * circle * specular * 0.5;  // specular

    fragColor = vec4(col, 1.0);
}
