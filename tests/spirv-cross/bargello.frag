#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test bargello / flame stitch embroidery pattern
void main() {
    vec2 p = uv * 16.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Bargello: zigzag peaks that shift per column
    float col_offset = sin(id.x * 0.5) * 0.3 + sin(id.x * 1.5) * 0.2;
    
    // Peak position shifts per column
    float peak = 0.5 + col_offset;
    peak = clamp(peak, 0.1, 0.9);
    
    // Zigzag: V shape
    float zigzag;
    float t = fp.y;
    float center_dist = abs(t - peak);
    float v_shape = center_dist / peak;
    
    // Color bands based on height
    float band = floor(fp.y * 8.0 + col_offset * 4.0);
    band = fract(band * 0.618);
    
    // Color palette: warm gradient
    vec3 c1 = vec3(0.8, 0.15, 0.1);   // red
    vec3 c2 = vec3(0.9, 0.5, 0.1);    // orange
    vec3 c3 = vec3(0.85, 0.8, 0.1);   // yellow
    vec3 c4 = vec3(0.6, 0.1, 0.3);    // burgundy
    vec3 c5 = vec3(0.3, 0.05, 0.1);   // dark red
    
    // Select color based on band
    vec3 band_col;
    if (band < 0.2) band_col = c1;
    else if (band < 0.4) band_col = c2;
    else if (band < 0.6) band_col = c3;
    else if (band < 0.8) band_col = c4;
    else band_col = c5;
    
    vec3 col = band_col;
    
    // Subtle vertical stitch lines
    float stitch = smoothstep(0.03, 0.02, abs(fp.x - 0.5));
    col *= (1.0 - stitch * 0.1);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
