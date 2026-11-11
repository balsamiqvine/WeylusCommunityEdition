#include <metal_stdlib>
using namespace metal;

// Decoded frames are full-range BT.709 NV12 (Weylus tags them that way). Convert to RGB once at
// video resolution so the upscaler works on RGB.
kernel void yuvToRgb(texture2d<float, access::read> yTex [[texture(0)]],
                     texture2d<float, access::sample> cbcrTex [[texture(1)]],
                     texture2d<float, access::write> outTex [[texture(2)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height())
        return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float y = yTex.read(gid).r;
    float2 uv = (float2(gid) + 0.5) / float2(outTex.get_width(), outTex.get_height());
    float2 c = cbcrTex.sample(s, uv).rg - 0.5;
    float3 rgb = float3(y + 1.5748 * c.y,
                        y - 0.1873 * c.x - 0.4681 * c.y,
                        y + 1.8556 * c.x);
    outTex.write(float4(saturate(rgb), 1.0), gid);
}

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// One triangle that covers the whole viewport.
vertex VOut fullscreenVertex(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 presentFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
