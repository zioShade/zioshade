#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dewdrop on tessellated surface
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Tile color
    float h = hash(id);
    vec3 tile_col = mix(vec3(0.3, 0.5, 0.4), vec3(0.4, 0.55, 0.45), h);
    
    // Grout lines
    float grout = 1.0 - step(0.05, fp.x) * step(fp.x, 0.95) *
                          step(0.05, fp.y) * step(fp.y, 0.95);
    
    // Dewdrop: spherical lens distortion
    vec2 drop_center = vec2(0.4 + h * 0.2, 0.4 + hash(id + 100.0) * 0.2);
    vec2 dp = fp - drop_center;
    float drop_r = length(dp);
    float drop = smoothstep(0.2, 0.18, drop_r);
    
    // Refracted view through drop (shifted UV)
    vec2 refracted = (fp + dp * 0.5);
    float ref_h = hash(floor(refracted * 8.0));
    vec3 refracted_col = mix(vec3(0.25, 0.45, 0.35), vec3(0.35, 0.5, 0.4), ref_h);
    
    // Specular highlight on drop
    vec2 hl = dp - vec2(-0.06, -0.06);
    float spec = exp(-dot(hl, hl) * 80.0);
    
    vec3 col = tile_col;
    col = mix(col, vec3(0.3, 0.3, 0.3), grout);
    col = mix(col, refracted_col * 1.2, drop);
    col += spec * drop * 0.8;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
