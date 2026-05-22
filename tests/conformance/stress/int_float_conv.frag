// Tests: implicit int-to-float conversions in arithmetic
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // int + float arithmetic (implicit conversion)
    int i = 3;
    float f = i + 0.5;       // int + float -> float
    float g = i * 2.0;       // int * float -> float
    float h = i - 1;          // int - int -> int, then assign to float
    
    // int in float context
    float a = uv.x * i;       // float * int -> float
    float b = uv.y + i;       // float + int -> float
    
    vec3 col = vec3(f * 0.1, g * 0.1, h * 0.1) + vec3(a, b, 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
