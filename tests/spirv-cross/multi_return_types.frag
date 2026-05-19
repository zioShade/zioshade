#version 450

// Test: multiple functions with different return types
float getFloat(vec2 uv) { return uv.x + uv.y; }
vec2 getVec2(vec2 uv) { return uv * 2.0; }
vec3 getVec3(vec2 uv) { return vec3(uv, uv.x * uv.y); }
vec4 getVec4(vec2 uv) { return vec4(uv, 1.0 - uv.x, 1.0); }
int getInt(vec2 uv) { return int(uv.x * 10.0); }
bool getBool(vec2 uv) { return uv.x > 0.5; }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float f = getFloat(uv);
    vec2 v2 = getVec2(uv);
    vec3 v3 = getVec3(uv);
    vec4 v4 = getVec4(uv);
    int i = getInt(uv);
    bool b = getBool(uv);

    float r = f * 0.5;
    float g = v2.x * 0.5;
    float bl = float(b) * 0.5 + v3.z * 0.5;
    float a = float(i) / 10.0;

    gl_FragColor = vec4(r, g, bl, a);
}
