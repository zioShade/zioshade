// Test: complex geometric operations
#version 450

layout(location = 0) out vec4 fragColor;

vec3 closestPointOnTriangle(vec3 p, vec3 a, vec3 b, vec3 c) {
    vec3 ab = b - a;
    vec3 ac = c - a;
    vec3 ap = p - a;
    
    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);
    if (d1 <= 0.0 && d2 <= 0.0) return a;
    
    vec3 bp = p - b;
    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);
    if (d3 >= 0.0 && d4 <= d3) return b;
    
    vec3 cp = p - c;
    float d5 = dot(ab, cp);
    float d6 = dot(ac, cp);
    if (d6 >= 0.0 && d5 <= d6) return c;
    
    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
        float v = d1 / (d1 - d3);
        return a + v * ab;
    }
    
    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
        float w = d2 / (d2 - d6);
        return a + w * ac;
    }
    
    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
        float w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b + w * (c - b);
    }
    
    float denom = 1.0 / (va + vb + vc);
    float vn = vb * denom;
    float wn = vc * denom;
    return a + ab * vn + ac * wn;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec3 p = vec3(uv * 10.0, 5.0);
    vec3 a = vec3(2.0, 3.0, 0.0);
    vec3 b = vec3(8.0, 3.0, 0.0);
    vec3 c = vec3(5.0, 8.0, 0.0);
    
    vec3 closest = closestPointOnTriangle(p, a, b, c);
    float dist = length(p - closest);
    
    fragColor = vec4(vec3(1.0 / (1.0 + dist)), 1.0);
}
