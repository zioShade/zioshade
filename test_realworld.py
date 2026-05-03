#!/usr/bin/env python3
"""
Test glslpp against a curated collection of real-world GLSL shaders.
These cover diverse feature sets: ray marching, SDF, noise, fractals,
post-processing, image processing, procedural textures, etc.
"""

import os
import subprocess
import sys
import tempfile
import struct

GLSLPP_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.zig-cache', 'bin', 'conformance-runner.exe')
SPIRV_VAL = 'C:/VulkanSDK/1.4.341.1/Bin/spirv-val.exe'

GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'

# Real-world GLSL fragment shaders covering diverse features
# Each is a complete fragment shader with #version 430
SHADERS = {}

# ---------------------------------------------------------------------------
# 1. Classic Mandelbrot - loops, conditionals, float math
# ---------------------------------------------------------------------------
SHADERS["mandelbrot"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec2 c = uv * 3.0 - vec2(0.5, 0.0);
    vec2 z = vec2(0.0);
    float iter = 0.0;
    const float maxIter = 256.0;
    for (float i = 0.0; i < maxIter; i += 1.0) {
        z = vec2(z.x*z.x - z.y*z.y, 2.0*z.x*z.y) + c;
        if (dot(z, z) > 4.0) break;
        iter = i;
    }
    float f = iter / maxIter;
    vec3 col = 0.5 + 0.5 * cos(3.0 + f * 6.28 * 2.0 + vec3(0.0, 0.6, 1.0));
    if (iter >= maxIter - 1.0) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 2. Value noise / procedural texture - hash, noise, fract, floor
# ---------------------------------------------------------------------------
SHADERS["value_noise"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float hash(vec2 p) {
    float h = dot(p, vec2(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    mat2 rot = mat2(cos(0.5), sin(0.5), -sin(0.5), cos(0.5));
    for (int i = 0; i < 6; i++) {
        v += a * noise(p);
        p = rot * p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    float f = fbm(uv * 4.0 + iTime * 0.2);
    vec3 col = mix(vec3(0.2, 0.1, 0.0), vec3(0.9, 0.7, 0.3), f);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 3. Simple raymarching - SDF, min/max, normalize, dot, length
# ---------------------------------------------------------------------------
SHADERS["raymarching"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float sdSphere(vec3 p, float r) { return length(p) - r; }
float sdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float map(vec3 p) {
    float d = sdSphere(p, 1.0);
    float box = sdBox(p - vec3(sin(iTime) * 2.0, 0.0, 0.0), vec3(0.5));
    d = min(d, box);
    float ground = p.y + 1.0;
    d = min(d, ground);
    return d;
}

vec3 calcNormal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx)
    ));
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec3 ro = vec3(0.0, 1.0, -4.0);
    vec3 rd = normalize(vec3(uv, 1.0));
    float t = 0.0;
    for (int i = 0; i < 100; i++) {
        vec3 p = ro + rd * t;
        float d = map(p);
        if (d < 0.001) break;
        if (t > 20.0) break;
        t += d;
    }
    vec3 col = vec3(0.1);
    if (t < 20.0) {
        vec3 p = ro + rd * t;
        vec3 n = calcNormal(p);
        vec3 light = normalize(vec3(1.0, 2.0, -1.0));
        float diff = max(dot(n, light), 0.0);
        col = vec3(0.8, 0.3, 0.2) * diff + vec3(0.1);
    }
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 4. 2D SDF operations - smooth min, boolean ops
# ---------------------------------------------------------------------------
SHADERS["sdf2d"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float sdCircle(vec2 p, float r) { return length(p) - r; }

float sdBox2d(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    float d1 = sdCircle(uv, 0.3);
    float d2 = sdBox2d(uv - vec2(sin(iTime) * 0.3, 0.0), vec2(0.2));
    float d = smin(d1, d2, 0.1);
    vec3 col = vec3(1.0) - vec3(smoothstep(0.0, 0.01, d));
    col *= vec3(0.3, 0.6, 0.9);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 5. Voronoi - distance comparisons, arrays (indirect via min)
# ---------------------------------------------------------------------------
SHADERS["voronoi"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy * 5.0;
    vec2 ip = floor(uv);
    vec2 fp = fract(uv);
    float minDist = 10.0;
    vec2 minPoint = vec2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = hash2(ip + neighbor);
            point = 0.5 + 0.5 * sin(iTime + 6.2831 * point);
            float d = length(neighbor + point - fp);
            if (d < minDist) {
                minDist = d;
                minPoint = point;
            }
        }
    }
    vec3 col = vec3(minDist);
    col *= vec3(0.5 + 0.5 * minPoint.x, 0.3 + 0.3 * minPoint.y, 0.8);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 6. Fire shader - noise, FBM, color ramps
# ---------------------------------------------------------------------------
SHADERS["fire"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
        mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x),
        f.y
    );
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    uv.y -= 1.0;
    float f = fbm(uv * 4.0 + vec2(0.0, -iTime * 2.0));
    f = f * f * f * f + f * f * f;
    vec3 col = mix(vec3(1.0, 0.3, 0.0), vec3(1.0, 0.9, 0.2), f);
    col = mix(vec3(0.0), col, f);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 7. Post-processing: chromatic aberration + vignette
# ---------------------------------------------------------------------------
SHADERS["chromatic_aberration"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 dir = uv - 0.5;
    float dist = length(dir);
    float aberration = 0.01 * dist;
    
    float r = texture(iChannel0, uv + dir * aberration).r;
    float g = texture(iChannel0, uv).g;
    float b = texture(iChannel0, uv - dir * aberration).b;
    vec3 col = vec3(r, g, b);
    
    // Vignette
    float vig = 1.0 - dist * 0.8;
    col *= vig;
    
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 8. Swirl / warp effect
# ---------------------------------------------------------------------------
SHADERS["swirl"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 center = vec2(0.5);
    vec2 d = uv - center;
    float dist = length(d);
    float angle = dist * 10.0 - iTime * 2.0;
    float s = sin(angle);
    float c = cos(angle);
    d = vec2(d.x * c - d.y * s, d.x * s + d.y * c);
    d = d * smoothstep(0.5, 0.0, dist) + d * (1.0 - smoothstep(0.5, 0.0, dist));
    vec2 newUv = center + d;
    vec4 col = texture(iChannel0, clamp(newUv, 0.0, 1.0));
    fragColor = col;
}
"""

# ---------------------------------------------------------------------------
# 9. Julia set - complex math, loops
# ---------------------------------------------------------------------------
SHADERS["julia"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec2 c = vec2(-0.8 + 0.2 * cos(iTime * 0.1), 0.156 + 0.1 * sin(iTime * 0.13));
    vec2 z = uv * 2.5;
    float iter = 0.0;
    for (int i = 0; i < 200; i++) {
        z = vec2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        if (dot(z, z) > 4.0) break;
        iter += 1.0;
    }
    float f = iter / 200.0;
    vec3 col = 0.5 + 0.5 * cos(f * 6.28 * 3.0 + vec3(1.0, 0.5, 0.0) + iTime * 0.3);
    if (iter >= 199.0) col = vec3(0.0);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 10. Plasma effect - sin, cos, mixing
# ---------------------------------------------------------------------------
SHADERS["plasma"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    float v1 = sin(uv.x * 10.0 + iTime);
    float v2 = sin(10.0 * (uv.x * sin(iTime * 0.5) + uv.y * cos(iTime * 0.3)) + iTime);
    float v3 = sin(sqrt(100.0 * ((uv.x - 0.5) * (uv.x - 0.5) + (uv.y - 0.5) * (uv.y - 0.5)) + 1.0) + iTime);
    float v4 = sin(sqrt(100.0 * ((uv.x - 0.5) * (uv.x - 0.5) + (uv.y - 0.5) * (uv.y - 0.5) + 1.0)) + iTime);
    float v = v1 + v2 + v3 + v4;
    vec3 col = vec3(
        sin(v) * 0.5 + 0.5,
        sin(v + 3.14159 * 0.666) * 0.5 + 0.5,
        sin(v + 3.14159 * 1.333) * 0.5 + 0.5
    );
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 11. Glow/bloom post-process - multiple texture samples, blur
# ---------------------------------------------------------------------------
SHADERS["bloom"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 col = texture(iChannel0, uv).rgb;
    
    // Simple 9-tap blur for bloom
    vec3 bloom = vec3(0.0);
    float total = 0.0;
    for (int x = -4; x <= 4; x++) {
        for (int y = -4; y <= 4; y++) {
            vec2 offset = vec2(float(x), float(y)) / iResolution.xy * 4.0;
            float weight = 1.0 / (1.0 + float(x*x + y*y));
            bloom += texture(iChannel0, uv + offset).rgb * weight;
            total += weight;
        }
    }
    bloom /= total;
    
    // Extract bright parts
    float brightness = dot(bloom, vec3(0.2126, 0.7152, 0.0722));
    bloom = bloom * smoothstep(0.4, 0.8, brightness);
    
    col += bloom * 0.6;
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 12. Perlin-like noise terrain
# ---------------------------------------------------------------------------
SHADERS["terrain"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i + vec2(0,0)), hash(i + vec2(1,0)), f.x),
        mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x),
        f.y
    );
}

float terrain(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 6; i++) {
        v += a * noise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    float t = terrain(uv * 3.0 + iTime * 0.1);
    vec3 col = mix(vec3(0.2, 0.5, 0.1), vec3(0.6, 0.4, 0.2), t);
    col = mix(col, vec3(1.0), smoothstep(0.65, 0.75, t));
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 13. Water waves - reflection, refraction simulation
# ---------------------------------------------------------------------------
SHADERS["water"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 p = uv * 8.0;
    
    float h = 0.0;
    for (int i = 0; i < 10; i++) {
        float fi = float(i);
        h += sin(p.x * (0.5 + fi * 0.1) + iTime * (1.0 + fi * 0.2)) * 0.5 / (1.0 + fi);
        h += sin(p.y * (0.3 + fi * 0.15) + iTime * (0.8 + fi * 0.1)) * 0.5 / (1.0 + fi);
    }
    
    // Fake normal from height
    float dx = h - sin((p.x + 0.01) * 0.5 + iTime) * 0.5;
    float dy = h - sin((p.y + 0.01) * 0.3 + iTime * 0.8) * 0.5;
    vec3 n = normalize(vec3(dx, dy, 0.02));
    
    vec3 light = normalize(vec3(1.0, 1.0, 0.5));
    float diff = max(dot(n, light), 0.0);
    float spec = pow(max(dot(reflect(-light, n), vec3(0.0, 0.0, 1.0)), 0.0), 32.0);
    
    vec3 col = vec3(0.0, 0.2, 0.4) + vec3(0.1, 0.3, 0.5) * diff + vec3(1.0) * spec * 0.5;
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 14. Kuwahara filter (image processing) - nested loops, arrays
# ---------------------------------------------------------------------------
SHADERS["kuwahara"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 texel = 1.0 / iResolution;
    
    int radius = 3;
    vec4 mean[4] = vec4[](vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
    float var[4] = float[](0.0, 0.0, 0.0, 0.0);
    
    for (int i = -radius; i <= 0; i++) {
        for (int j = -radius; j <= 0; j++) {
            vec4 c = texture(iChannel0, uv + vec2(float(i), float(j)) * texel);
            mean[0] += c;
        }
    }
    mean[0] /= float((radius + 1) * (radius + 1));
    
    for (int i = 0; i <= radius; i++) {
        for (int j = -radius; j <= 0; j++) {
            vec4 c = texture(iChannel0, uv + vec2(float(i), float(j)) * texel);
            mean[1] += c;
        }
    }
    mean[1] /= float((radius + 1) * (radius + 1));
    
    for (int i = -radius; i <= 0; i++) {
        for (int j = 0; j <= radius; j++) {
            vec4 c = texture(iChannel0, uv + vec2(float(i), float(j)) * texel);
            mean[2] += c;
        }
    }
    mean[2] /= float((radius + 1) * (radius + 1));
    
    for (int i = 0; i <= radius; i++) {
        for (int j = 0; j <= radius; j++) {
            vec4 c = texture(iChannel0, uv + vec2(float(i), float(j)) * texel);
            mean[3] += c;
        }
    }
    mean[3] /= float((radius + 1) * (radius + 1));
    
    // Compute variance for each quadrant
    float minVar = 1e10;
    vec4 result = mean[0];
    for (int k = 0; k < 4; k++) {
        var[k] = dot(mean[k].rgb, mean[k].rgb);
        if (var[k] < minVar) {
            minVar = var[k];
            result = mean[k];
        }
    }
    
    fragColor = result;
}
"""

# ---------------------------------------------------------------------------
# 15. Starfield - particle rendering, loops, sin/cos
# ---------------------------------------------------------------------------
SHADERS["starfield"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float hash(float n) { return fract(sin(n) * 43758.5453123); }

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 200; i++) {
        float fi = float(i);
        float x = hash(fi) * 2.0 - 1.0;
        float y = hash(fi + 1000.0) * 2.0 - 1.0;
        float z = hash(fi + 2000.0);
        float speed = 0.5 + z * 2.0;
        
        vec3 star = vec3(x, y, fract(z + iTime * speed * 0.1));
        star.xy *= 1.0 / (star.z * 2.0 + 0.5);
        star.xy += uv * star.z * 0.5;
        
        float d = length(star.xy - uv);
        float brightness = 0.002 / (d * d + 0.0001);
        brightness = min(brightness, 50.0);
        
        vec3 starCol = mix(vec3(0.8, 0.9, 1.0), vec3(1.0, 0.8, 0.5), hash(fi + 3000.0));
        col += starCol * brightness * 0.01;
    }
    
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 16. Matrix rain (character grid) - integer math, mod, arrays
# ---------------------------------------------------------------------------
SHADERS["matrix_rain"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    uv.y = 1.0 - uv.y;
    
    float scale = 20.0;
    vec2 gv = fract(uv * scale) - 0.5;
    vec2 id = floor(uv * scale);
    
    float n = hash(id);
    float col_idx = floor(n * 4.0);
    
    float speed = 1.0 + n * 3.0;
    float y_offset = hash(vec2(id.x, 0.0));
    float y = fract(iTime * speed * 0.2 + y_offset);
    
    float head_y = 1.0 - y;
    float dist = id.y / scale - head_y;
    
    float brightness = smoothstep(0.5, 0.0, abs(dist));
    brightness += smoothstep(0.3, 0.0, -dist) * 0.3;
    
    // Leading character is brighter
    float is_head = smoothstep(0.02, 0.0, abs(dist));
    brightness += is_head * 2.0;
    
    vec3 col = vec3(0.0);
    col.g = brightness;
    col.r = is_head * 0.3;
    
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 17. Motion blur
# ---------------------------------------------------------------------------
SHADERS["motion_blur"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 col = vec3(0.0);
    float samples = 8.0;
    vec2 velocity = vec2(0.01, 0.005);
    
    for (float i = 0.0; i < samples; i += 1.0) {
        vec2 offset = velocity * (i / samples - 0.5);
        col += texture(iChannel0, uv + offset).rgb;
    }
    col /= samples;
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 18. Edge detection (Sobel)
# ---------------------------------------------------------------------------
SHADERS["edge_detection"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform sampler2D iChannel0;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 texel = 1.0 / iResolution;
    
    float tl = dot(texture(iChannel0, uv + vec2(-1, -1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float t  = dot(texture(iChannel0, uv + vec2( 0, -1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float tr = dot(texture(iChannel0, uv + vec2( 1, -1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float l  = dot(texture(iChannel0, uv + vec2(-1,  0) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float r  = dot(texture(iChannel0, uv + vec2( 1,  0) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float bl = dot(texture(iChannel0, uv + vec2(-1,  1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float b  = dot(texture(iChannel0, uv + vec2( 0,  1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    float br = dot(texture(iChannel0, uv + vec2( 1,  1) * texel).rgb, vec3(0.299, 0.587, 0.114));
    
    float gx = tl + 2.0 * l + bl - tr - 2.0 * r - br;
    float gy = tl + 2.0 * t + tr - bl - 2.0 * b - br;
    
    float edge = sqrt(gx * gx + gy * gy);
    vec3 col = vec3(edge);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 19. Fractal flames
# ---------------------------------------------------------------------------
SHADERS["fractal_flame"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform float iTime;

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * iResolution.xy) / iResolution.y;
    vec2 z = uv * 2.0;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        // Vortex transform
        float r = length(z);
        float a = atan(z.y, z.x);
        a += sin(r * 3.0 - iTime) * 0.5;
        z = vec2(cos(a), sin(a)) * r;
        
        // Fold
        z = abs(z);
        z = z * 1.5 - vec2(1.0, 0.5);
        
        // Accumulate color
        float d = length(z);
        col += vec3(
            0.5 + 0.5 * sin(fi * 0.3 + iTime),
            0.5 + 0.5 * sin(fi * 0.3 + iTime + 2.0),
            0.5 + 0.5 * sin(fi * 0.3 + iTime + 4.0)
        ) * 0.05 / (d + 0.1);
    }
    
    col = clamp(col, 0.0, 1.0);
    fragColor = vec4(col, 1.0);
}
"""

# ---------------------------------------------------------------------------
# 20. Gamma/tonemap (simple image processing)
# ---------------------------------------------------------------------------
SHADERS["tonemap"] = """#version 430 core
layout(location = 0) out vec4 fragColor;
uniform vec2 iResolution;
uniform sampler2D iChannel0;

vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec3 col = texture(iChannel0, uv).rgb;
    col = ACESFilm(col * 1.5);
    col = pow(col, vec3(1.0 / 2.2));
    fragColor = vec4(col, 1.0);
}
"""


def compile_glslpp(source, output_path):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.glsl', delete=False, encoding='utf-8') as f:
        f.write(source)
        temp_path = f.name
    try:
        result = subprocess.run(
            [GLSLPP_RUNNER, temp_path, '--save-spv', output_path],
            capture_output=True, text=True, timeout=15
        )
        if os.path.exists(output_path):
            return True, result.stdout + result.stderr
        return False, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)
    finally:
        os.unlink(temp_path)


def validate_spv(path):
    result = subprocess.run([SPIRV_VAL, path], capture_output=True, text=True, timeout=10)
    return result.returncode == 0, result.stdout + result.stderr


def get_bound(path):
    with open(path, 'rb') as f:
        data = f.read(20)
    if len(data) < 20:
        return None
    return struct.unpack('<5I', data)[3]


def main():
    if not os.path.exists(GLSLPP_RUNNER):
        print(f"{RED}glslpp runner not found{RESET}")
        sys.exit(1)
    
    print(f"{BLUE}Real-World GLSL Shader Audit{RESET}")
    print(f"  Shaders: {len(SHADERS)}")
    print()
    
    results = []
    for name, source in sorted(SHADERS.items()):
        spv_path = os.path.join(os.environ.get('TEMP', '/tmp'), f'glslpp_test_{name}.spv')
        
        ok, output = compile_glslpp(source, spv_path)
        if not ok:
            err = [l for l in output.split('\n') if 'error' in l.lower() or 'COMPILE' in l or 'spirv-val' in l]
            err_str = err[0][:100] if err else output[:100]
            print(f"  {RED}COMPILE FAIL{RESET} {name}: {err_str}")
            results.append({'name': name, 'status': 'compile_fail', 'error': err_str})
            continue
        
        valid, val_output = validate_spv(spv_path)
        if not valid:
            val_lines = [l for l in val_output.split('\n') if l.strip()]
            val_str = val_lines[0][:100] if val_lines else val_output[:100]
            print(f"  {RED}VAL FAIL{RESET} {name}: {val_str}")
            results.append({'name': name, 'status': 'val_fail', 'error': val_str})
            continue
        
        bound = get_bound(spv_path)
        print(f"  {GREEN}PASS{RESET} {name} bound={bound}")
        results.append({'name': name, 'status': 'pass', 'bound': bound})
    
    total = len(results)
    passed = sum(1 for r in results if r['status'] == 'pass')
    fails = [r for r in results if r['status'] != 'pass']
    
    print(f"\n{BLUE}{'='*50}{RESET}")
    print(f"  PASS: {passed}/{total}")
    if fails:
        print(f"\n{RED}FAILURES:{RESET}")
        for r in fails:
            print(f"  {RED}X{RESET} {r['name']}: {r.get('error','')[:80]}")
    
    if passed == total:
        print(f"\n{GREEN}ALL {total} SHADERS PASS!{RESET}")
    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
