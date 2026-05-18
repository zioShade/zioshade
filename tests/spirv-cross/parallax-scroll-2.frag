#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multi-layer parallax with depth
void main() {
    // Far layer (mountains)
    vec2 far_uv = uv * 3.0;
    float far = sin(far_uv.x * 2.0) * cos(far_uv.y * 1.5);
    far = far * 0.5 + 0.5;
    
    // Mid layer (hills)
    vec2 mid_uv = uv * 5.0;
    float mid = sin(mid_uv.x * 1.5 + 0.5) * cos(mid_uv.y * 2.0 + 0.3);
    mid = mid * 0.5 + 0.5;
    
    // Near layer (grass)
    vec2 near_uv = uv * 10.0;
    float near = sin(near_uv.x * 3.0 + 1.0) * cos(near_uv.y * 4.0 + 0.7);
    near = near * 0.5 + 0.5;
    
    vec3 sky = vec3(0.4, 0.6, 0.9);
    vec3 mountain = vec3(0.3, 0.35, 0.4) * far;
    vec3 hill = vec3(0.2, 0.5, 0.2) * mid;
    vec3 grass = vec3(0.15, 0.4, 0.1) * near;
    
    vec3 col = sky;
    float y = uv.y;
    if (y > 0.65) col = mix(sky, mountain, smoothstep(0.65, 0.6, y));
    if (y > 0.4) col = mix(col, hill, smoothstep(0.4, 0.35, y));
    col = mix(col, grass, smoothstep(0.35, 0.3, y));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
