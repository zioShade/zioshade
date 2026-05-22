// Tests: nested struct with default values and conditional modification
precision mediump float;
uniform vec2 u_resolution;

struct Transform2D {
    vec2 offset;
    float rotation;
    float scale;
};

struct Object2D {
    Transform2D transform;
    vec3 color;
    int type;
};

vec2 applyTransform(Transform2D t, vec2 p) {
    float c = cos(t.rotation);
    float s = sin(t.rotation);
    vec2 rotated = vec2(c * p.x - s * p.y, s * p.x + c * p.y);
    return rotated * t.scale + t.offset;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Object2D obj;
    obj.transform.offset = vec2(0.5);
    obj.transform.rotation = uv.x * 6.28;
    obj.transform.scale = 1.0;
    obj.color = vec3(0.8, 0.4, 0.2);
    obj.type = int(uv.y * 3.999);
    
    vec2 transformed = applyTransform(obj.transform, uv);
    
    vec3 col = obj.color;
    if (obj.type == 0) {
        col = vec3(length(transformed));
    } else if (obj.type == 1) {
        col *= vec3(fract(transformed.x), fract(transformed.y), 0.5);
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
