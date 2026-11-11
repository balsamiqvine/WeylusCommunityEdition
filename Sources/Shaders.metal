#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------------------------
// 1. YUV -> RGB with luma-guided chroma upsampling
//
// Frames are full-range BT.709 NV12: colour is stored at half resolution. Weylus' encoder (the
// VAAPI converter) takes each 2x2 block's colour from its top-left pixel, so chroma texel (i, j)
// belongs to luma pixel (2i, 2j). Plain bilinear upsampling smears colour across sharp edges,
// which shows up as red/blue fringes around text and UI lines. Instead, each of the 4 nearest
// chroma samples is weighted by how similar the luma at its position is to this pixel's luma (a
// joint bilateral filter), so colour stops where brightness edges are. Measured on a sharp-edge
// test pattern at the stream's quality, this cuts fringing on white/grey by ~90%.
// ---------------------------------------------------------------------------------------------

struct ConvertParams {
    float inv2Sigma2; // 0 disables the luma guide (plain distance-weighted upsampling)
};

kernel void yuvToRgb(texture2d<float, access::read> yTex [[texture(0)]],
                     texture2d<float, access::read> cTex [[texture(1)]],
                     texture2d<float, access::write> outTex [[texture(2)]],
                     constant ConvertParams &params [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height())
        return;
    float y = yTex.read(gid).r;
    int2 cmax = int2(cTex.get_width() - 1, cTex.get_height() - 1);
    int2 lmax = int2(yTex.get_width() - 1, yTex.get_height() - 1);
    float2 cpos = float2(gid) * 0.5;
    int2 base = int2(floor(cpos));
    float2 acc = float2(0.0);
    float wsum = 0.0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            int2 c = clamp(base + int2(i, j), int2(0), cmax);
            float2 d = cpos - float2(base + int2(i, j));
            float w = exp(-dot(d, d));
            float yl = yTex.read(uint2(clamp(c * 2, int2(0), lmax))).r;
            float dy = y - yl;
            w *= exp(-dy * dy * params.inv2Sigma2);
            w += 1e-6;
            acc += w * (cTex.read(uint2(c)).rg - 0.5);
            wsum += w;
        }
    }
    float2 cbcr = acc / wsum;
    float3 rgb = float3(y + 1.5748 * cbcr.y,
                        y - 0.1873 * cbcr.x - 0.4681 * cbcr.y,
                        y + 1.8556 * cbcr.x);
    outTex.write(float4(saturate(rgb), 1.0), gid);
}

// ---------------------------------------------------------------------------------------------
// Fullscreen triangle
// ---------------------------------------------------------------------------------------------

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut fullscreenVertex(uint vid [[vertex_id]])
{
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// ---------------------------------------------------------------------------------------------
// 2. Upscalers (render into a texture at the screen's native pixel size)
// ---------------------------------------------------------------------------------------------

static float4 texel(texture2d<float> t, int2 p)
{
    int2 m = int2(t.get_width() - 1, t.get_height() - 1);
    return t.read(uint2(clamp(p, int2(0), m)));
}

fragment float4 upscaleBilinear(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

fragment float4 upscaleNearest(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}

static float catmullRom(float x)
{
    x = abs(x);
    if (x < 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
    if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
    return 0.0;
}

fragment float4 upscaleBicubic(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 p = in.uv * size - 0.5;
    float2 f = floor(p);
    float2 t = p - f;
    float4 acc = float4(0.0);
    float wsum = 0.0;
    for (int j = -1; j <= 2; j++) {
        float wy = catmullRom(float(j) - t.y);
        for (int i = -1; i <= 2; i++) {
            float w = catmullRom(float(i) - t.x) * wy;
            acc += w * texel(tex, int2(f) + int2(i, j));
            wsum += w;
        }
    }
    return saturate(acc / wsum);
}

static float lanczos3(float x)
{
    x = abs(x);
    if (x < 1e-5) return 1.0;
    if (x >= 3.0) return 0.0;
    float px = M_PI_F * x;
    return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
}

fragment float4 upscaleLanczos(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]])
{
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 p = in.uv * size - 0.5;
    float2 f = floor(p);
    float2 t = p - f;
    float wx[6], wy[6];
    for (int i = 0; i < 6; i++) {
        wx[i] = lanczos3(float(i - 2) - t.x);
        wy[i] = lanczos3(float(i - 2) - t.y);
    }
    float4 acc = float4(0.0);
    float wsum = 0.0;
    for (int j = 0; j < 6; j++) {
        for (int i = 0; i < 6; i++) {
            float w = wx[i] * wy[j];
            acc += w * texel(tex, int2(f) + int2(i - 2, j - 2));
            wsum += w;
        }
    }
    return saturate(acc / wsum);
}

// ---------------------------------------------------------------------------------------------
// 3. Present with AMD FidelityFX FSR 1.0 RCAS ("robust contrast-adaptive sharpening").
// Source is already at output resolution, so this reads 1:1. sharpness 0 = plain copy.
// ---------------------------------------------------------------------------------------------

struct PresentParams {
    float sharpness; // 0..1
};

fragment float4 presentRCAS(VOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            constant PresentParams &params [[buffer(0)]])
{
    int2 p = int2(in.pos.xy);
    float3 e = texel(tex, p).rgb;
    if (params.sharpness <= 0.0)
        return float4(e, 1.0);
    float3 b = texel(tex, p + int2(0, -1)).rgb;
    float3 d = texel(tex, p + int2(-1, 0)).rgb;
    float3 f = texel(tex, p + int2(1, 0)).rgb;
    float3 h = texel(tex, p + int2(0, 1)).rgb;
    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));
    // Largest negative lobe that neither clips below 0 nor above 1 (RCAS' "solve for no clip").
    float3 hitMin = min(mn4, e) / (4.0 * mx4 + 1e-5);
    float3 hitMax = (1.0 - max(mx4, e)) / min(4.0 * mn4 - 4.0, -1e-5);
    float3 lobeRGB = max(-hitMin, hitMax);
    const float RCAS_LIMIT = 0.25 - (1.0 / 16.0);
    float lobe = max(-RCAS_LIMIT, min(max(lobeRGB.r, max(lobeRGB.g, lobeRGB.b)), 0.0)) * params.sharpness;
    float3 c = (lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0);
    return float4(saturate(c), 1.0);
}
