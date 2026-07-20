// Fullscreen-triangle vertex shader: emits one oversized triangle covering the
// viewport from SV_VertexID alone (no vertex buffer). Mirrors the Metal
// full_screen_vertex in tools/ShaderCompare.swift so the WARP render and the
// macOS Metal render rasterize the same coverage and gl_FragCoord/SV_Position
// values. Compile: dxc -T vs_6_0 -E VSMain fullscreen_vs.hlsl -Fo fullscreen.vs.cso
float4 VSMain(uint vid : SV_VertexID) : SV_Position
{
    float2 p;
    p.x = (vid == 2) ? 3.0 : -1.0;
    p.y = (vid == 0) ? -3.0 : 1.0;
    return float4(p, 0.0, 1.0);
}
