#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Crystal / gemstone facets
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Hexagonal facets
    float sectors = 6.0;
    float sector_a = floor(a * sectors / 6.28) * 6.28 / sectors;
    vec2 facet_dir = vec2(cos(sector_a), sin(sector_a));
    float facet_dot = dot(uv, facet_dir);
    float facet = facet_dot / max(r, 0.001);
    // Facet shading
    float shade = facet * 0.5 + 0.5;
    // Prismatic color per facet
    float facet_id = floor(a * sectors / 6.28);
    float hue = fract(facet_id / sectors);
    vec3 col = vec3(
        sin(hue * 6.28) * 0.5 + 0.5,
        sin(hue * 6.28 + 2.09) * 0.5 + 0.5,
        sin(hue * 6.28 + 4.18) * 0.5 + 0.5
    ) * shade;
    col *= smoothstep(0.85, 0.8, r);
    fragColor = vec4(col, 1.0);
}
