#version 430

layout(binding = 1, std140) uniform Globals
{
    vec3 Globals_m0;
    float Globals_m1;
    float Globals_m2;
    float Globals_m3;
    int Globals_m4;
    float Globals_m5[4];
    vec3 Globals_m6[4];
    vec4 Globals_m7;
    vec4 Globals_m8;
    float Globals_m9;
    vec4 Globals_m10;
    vec4 Globals_m11;
    vec4 Globals_m12;
    vec4 Globals_m13;
    int Globals_m14;
    int Globals_m15;
    int Globals_m16;
    float Globals_m17;
    float Globals_m18;
    int Globals_m19;
    vec3 Globals_m20[256];
    vec3 Globals_m21;
    vec3 Globals_m22;
    vec3 Globals_m23;
    vec3 Globals_m24;
    vec3 Globals_m25;
    vec3 Globals_m26;
} Globals_1;

layout(binding = 0) uniform sampler2D iChannel0;



void mainImage(out vec4 v27, vec2 v28)
{
    vec3 v29;
    vec3 v31 = Globals_1.Globals_m0;
    vec2 v32 = vec2(v31.x, v31.y);
    vec2 v33 = v28 / v32;
    vec4 v35 = texture(iChannel0, v33);
    vec3 v36 = vec3(v35.x, v35.y, v35.z);
    int v38 = Globals_1.Globals_m19;
    bool v39 = v38 > 0;
    v29 = v36;
    if (v39)
    {
    float v41 = Globals_1.Globals_m1;
    float v43 = Globals_1.Globals_m18;
    float v44 = v41 - v43;
    float v45 = v44 / 3.0;
    float v46 = 1.0 - v45;
    float v47 = max(0.0, v46);
    float v48 = v47 * 0.4;
    vec3 v49 = vec3(v48, v48, v48);
    vec3 v50 = mix(v36, vec3(0.0, 1.0, 0.0), v49);
    v29 = v50;
    float v51 = v28.x;
    bool v52 = v51 < 5.0;
    float v53 = v31.x;
    float v54 = v53 - 5.0;
    bool v55 = v51 > v54;
    bool v56 = v52 || v55;
    float v57 = v28.y;
    bool v58 = v57 < 5.0;
    bool v59 = v56 || v58;
    float v60 = v31.y;
    float v61 = v60 - 5.0;
    bool v62 = v57 > v61;
    bool v63 = v59 || v62;
        if (v63)
        {
    float v64 = v44 * 2.0;
    float v65 = sin(v64);
    float v66 = v65 * 0.1;
    float v67 = v66 + 0.9;
    vec3 v68 = vec3(0.0, 1.0, 1.0) * v67;
    v29 = v68;
        }
    } else {
    vec3 v69 = v29;
    vec3 v70 = vec3(0.3, 0.3, 0.3);
    vec3 v71 = mix(v69, vec3(1.0, 0.0, 0.0), v70);
    v29 = v71;
    }
    vec3 v72 = v29;
    float v73 = v72.x;
    float v74 = v72.y;
    float v75 = v72.z;
    vec4 v76 = vec4(v73, v74, v75, 1.0);
    v27 = v76;
    return;
}
layout(location = 0) out vec4 _fragColor;

void main()
{
    vec2 v25 = vec2(gl_FragCoord.x, gl_FragCoord.y);
    mainImage(_fragColor, v25);
}
