#version 430
layout(location = 0) out vec4 FragColor;

// Test: basic Phong shading
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 normal = normalize(vec3(uv * 2.0 - 1.0, 0.5));
    vec3 lightPos = vec3(1.0, 1.0, 2.0);
    vec3 lightDir = normalize(lightPos - vec3(uv, 0.0));
    vec3 viewDir = vec3(0.0, 0.0, 1.0);
    vec3 reflectDir = reflect(-lightDir, normal);

    float ambient = 0.2;
    float diffuse = max(dot(normal, lightDir), 0.0);
    float specular = pow(max(dot(viewDir, reflectDir), 0.0), 16.0);

    vec3 col = vec3(0.6, 0.4, 0.3) * (ambient + diffuse) + vec3(1.0) * specular * 0.5;
    FragColor = vec4(col, 1.0);
}
