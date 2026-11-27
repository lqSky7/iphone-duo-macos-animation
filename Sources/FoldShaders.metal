#include <metal_stdlib>
using namespace metal;

constant float MAX_TILT = 0.84106867; // acos(1.0 / 1.5)
constant float3 DARK = float3(0.003, 0.004, 0.005);

struct Uniforms {
    float2 imageSize;
    float2 cover;
    float aspect;
    float turn;
    float blurStrength;
    float reflectionIntensity;
    float sampleCount;   // adaptive quality: 12 / 20 / 32 (float for Swift layout parity)
    float motionBoost;   // velocity-aware extra blur radius (0 = still, larger = fast close)
    float sideVoid;      // 0 = frame keeps full width, 1 = physical default, >1 = deeper side blackout
    float duoMode;       // 1 = Duo Mode (upright picture), 0 = original fold
    float startAngle;    // lid angle (deg) where turn = 0
    float endAngle;      // lid angle (deg) where turn = 1
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut foldVertex(uint vid [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    
    VertexOut out;
    float2 pos = positions[vid];
    out.position = float4(pos, 0.0, 1.0);
    // UV origin: (0,0) at top-left, (1,1) at bottom-right
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return out;
}

// True gaussian downsample: binomial 3x3 (σ ≈ 1.2 source texels), rendered
// once per texture upload into each mip level. Chained levels double σ, so
// mip k holds a genuine blur of σ ≈ 1.2 · 2^k texels — not a box average.
struct PyramidParams {
    float2 srcTexel;
    float srcLod;
    float pad;
};

fragment float4 gaussianDownsampleFragment(VertexOut in [[stage_in]],
                                           texture2d<float> tex [[texture(0)]],
                                           sampler s [[sampler(0)]],
                                           constant PyramidParams &p [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 acc = tex.sample(s, uv, level(p.srcLod)).rgb * 4.0;
    acc += tex.sample(s, uv + float2( p.srcTexel.x, 0.0), level(p.srcLod)).rgb * 2.0;
    acc += tex.sample(s, uv + float2(-p.srcTexel.x, 0.0), level(p.srcLod)).rgb * 2.0;
    acc += tex.sample(s, uv + float2(0.0,  p.srcTexel.y), level(p.srcLod)).rgb * 2.0;
    acc += tex.sample(s, uv + float2(0.0, -p.srcTexel.y), level(p.srcLod)).rgb * 2.0;
    acc += tex.sample(s, uv + float2( p.srcTexel.x,  p.srcTexel.y), level(p.srcLod)).rgb;
    acc += tex.sample(s, uv + float2(-p.srcTexel.x,  p.srcTexel.y), level(p.srcLod)).rgb;
    acc += tex.sample(s, uv + float2( p.srcTexel.x, -p.srcTexel.y), level(p.srcLod)).rgb;
    acc += tex.sample(s, uv + float2(-p.srcTexel.x, -p.srcTexel.y), level(p.srcLod)).rgb;
    return float4(acc / 16.0, 1.0);
}

inline float3 sampleSmoothMatteBlur(texture2d<float> tex,
                                    sampler s,
                                    float2 uv,
                                    float radius,
                                    float2 cover,
                                    float2 uiPixel,
                                    float2 screenCoord,
                                    int maxSamples) {
    float2 tuv = (uv - 0.5) * cover + 0.5;

    // When radius is near zero, return razor-sharp native Retina sample at level 0
    if (radius <= 0.15) {
        return tex.sample(s, tuv, level(0.0)).rgb;
    }

    // REAL GAUSSIAN BLUR via the pyramid (see gaussianDownsampleFragment):
    // each mip level is a true binomial blur with σ doubling per level, so
    // trilinear sampling at a radius-mapped LOD yields a smooth continuous
    // gaussian of ANY width. The old approach widened a sparse spatial tap
    // disc with radius — which is DISPERSION, not blur: bright text appeared
    // as multiple discrete ghost copies, plus frosted grain and white haze.
    float lod = clamp(log2(max(1.0, radius * 0.25)), 0.0, 5.0);

    // Tiny Vogel disc at the CURRENT mip's texel scale (±1.2 texels): dense,
    // heavily overlapping taps that polish trilinear level steps and edges —
    // the spread NEVER scales with radius, so dispersion cannot come back.
    float2 mipTexel = uiPixel * 0.5 * exp2(lod);

    // Minimal per-pixel micro-rotation to break residual ring banding.
    float rot = (fract(sin(dot(screenCoord, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.12;
    float cosRot = cos(rot);
    float sinRot = sin(rot);

    float3 accum = float3(0.0);
    float totalWeight = 0.0;

    constexpr int NUM_SAMPLES = 32;
    constexpr float GOLDEN_ANGLE = 2.39996323; // pi * (3.0 - sqrt(5.0))
    int activeSamples = clamp(maxSamples, 4, NUM_SAMPLES);

    for (int i = 0; i < NUM_SAMPLES; i++) {
        if (i >= activeSamples) { break; }
        float fi = float(i);
        float theta = fi * GOLDEN_ANGLE;
        float r = sqrt((fi + 0.5) / float(activeSamples));
        float uX = cos(theta);
        float uY = sin(theta);
        float dirX = uX * cosRot - uY * sinRot;
        float dirY = uX * sinRot + uY * cosRot;

        float2 offset = float2(dirX, dirY) * (r * 1.2 * mipTexel);
        float2 sampleUV = clamp(tuv + offset, 0.0, 1.0);
        float weight = exp(-2.3 * r * r);

        accum += tex.sample(s, sampleUV, level(lod)).rgb * weight;
        totalWeight += weight;
    }

    float3 blurred = accum / totalWeight;

    // Smooth transition from sharp to matte blur as fold begins
    float3 sharp = tex.sample(s, tuv, level(0.0)).rgb;
    return mix(sharp, blurred, smoothstep(0.0, 2.0, radius));
}

// "The picture stays upright." The lid is a window onto a virtual screen that
// follows the panel down to 90° and then stays standing while the lid keeps
// closing. Each pixel casts a ray from the viewer's eye through its spot on the
// real (tilting) panel and samples the virtual screen where the ray lands. The
// picture therefore shrinks away from the panel edges, black on the sides and
// top, while the hinge line stays put. Blur grows toward the top and with the fold.
inline float4 duoFold(VertexOut in,
                     texture2d<float> tex,
                     sampler s,
                     constant Uniforms &u) {
    float turn = clamp(u.turn, 0.0, 1.0);
    float2 uiPixel = 2.0 / max(float2(1.0), u.imageSize);
    int quality = int(clamp(u.sampleCount, 4.0, 32.0));

    if (turn <= 0.00001) {
        return float4(sampleSmoothMatteBlur(tex, s, in.uv, 0.0, u.cover, uiPixel, in.position.xy, quality), 1.0);
    }

    // Angles from the keyboard deck. Real panel follows the sensor; virtual screen
    // is the panel itself until 90°, then stays upright (or at start angle if < 90).
    float panel = mix(u.startAngle, u.endAngle, turn) * (M_PI_F / 180.0);
    float upright = min(u.startAngle, 90.0) * (M_PI_F / 180.0);
    // Lag between panel and virtual screen saturates softly at ~28°: beyond that the
    // picture leans along with the lid instead of stretching (grazing-angle smear).
    const float maxLag = 28.0 * (M_PI_F / 180.0);
    // Soft onset (softplus, ~6° wide): the picture lets go of the panel gradually
    // around 90° instead of stopping dead, which read as a hitch.
    const float onset = 6.0 * (M_PI_F / 180.0);
    float start = u.startAngle * (M_PI_F / 180.0);
    // Minus the value at the start angle, so the first frame is exactly the desktop.
    float engaged = max(onset * (log(1.0 + exp((upright - panel) / onset)) - log(1.0 + exp((upright - start) / onset))), 0.0);
    float virt = panel + maxLag * tanh(engaged / maxLag);

    // Units: panel height = 1. Hinge on the x axis, y up, z toward the viewer.
    float aspect = max(0.1, u.aspect);
    float fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
    float3 P = float3((in.uv.x - 0.5) * aspect, fromHinge * sin(panel), fromHinge * cos(panel));
    const float3 eye = float3(0.0, 0.7, 2.6); // tuned by eye on the real lid (a higher, 'realistic' eye looked worse)

    float3 vdir = float3(0.0, sin(virt), cos(virt));
    float3 vnorm = float3(0.0, cos(virt), -sin(virt));
    float3 ray = P - eye;
    float denom = dot(vnorm, ray);
    float t = abs(denom) > 1e-5 ? -dot(vnorm, eye) / denom : -1.0;
    float3 H = eye + ray * max(t, 0.0);
    float2 uv = float2(0.5 + H.x / aspect, 1.0 - dot(H, vdir));
    // Late in the fold the true projection stretches the picture vertically; ease the
    // vertical axis back toward the panel's own so it keeps its shape (sides stay physical).
    uv.y = mix(uv.y, in.uv.y, 0.65 * smoothstep(0.30, 0.80, turn));

    // Gradient blur: grows with the fold and toward the top of the panel.
    // Fixed Duo look: the user's Blur slider only drives the original fold.
    float radius = (160.0 * 0.5 * smoothstep(0.0, 0.6, turn) + clamp(u.motionBoost, 0.0, 24.0))
                 * smoothstep(0.05, 1.0, fromHinge);
    float3 color = sampleSmoothMatteBlur(tex, s, clamp(uv, 0.0, 1.0), radius, u.cover, uiPixel, in.position.xy, quality);
    color *= 1.0 - 0.45 * smoothstep(0.2, 1.0, turn) * fromHinge; // dims toward the top

    // Outside the virtual screen is the void (soft edge, softer when blurred).
    float2 edge = fwidth(uv) + radius * 0.0015;
    float2 inRange = smoothstep(-edge, edge, uv) * (1.0 - smoothstep(1.0 - edge, 1.0 + edge, uv));
    float mask = inRange.x * inRange.y * step(0.0, t);

    color *= 1.0 - smoothstep(0.55, 0.97, turn); // long fade: spread over the grazing end instead of a late rush
    return float4(mix(DARK, color, mask), 1.0);
}

// Original macTilt fold (Duo Mode off).
inline float4 classicFold(VertexOut in,
                     texture2d<float> tex,
                     sampler s,
                     constant Uniforms &u) {
    float turn = clamp(u.turn, 0.0, 1.0);
    float2 uiPixel = 2.0 / max(float2(1.0), u.imageSize);
    int quality = int(clamp(u.sampleCount, 4.0, 32.0));
    
    if (turn <= 0.00001) {
        return float4(sampleSmoothMatteBlur(tex, s, in.uv, 0.0, u.cover, uiPixel, in.position.xy, quality), 1.0);
    }
    
    // Up-to-Down Clamshell Fold: Hinge is at the bottom edge (in.uv.y = 1.0)
    float fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
    
    // Scale bend smoothly across the ENTIRE 0.0 -> 1.0 closing turn
    float bend = turn * MAX_TILT;
    float cosine = cos(bend);
    float sine = sin(bend);
    
    // Stable perspective projection that spans the whole closing arc without exploding
    float invAspect = 1.0 / max(0.1, u.aspect);
    float eye = 3.2 * max(invAspect, 1.0);
    float depth = fromHinge * (0.80 * invAspect) * sine;
    float perspective = eye / max(0.01, (eye - depth));
    
    float2 plane;
    plane.y = 1.0 - fromHinge * cosine * perspective;
    // Horizontal parallax spread. `perspective` pushes the folded plane wider
    // than the panel as it tilts away; the mask further down turns everything
    // outside the unit square into the void — that is the black that creeps in
    // from the left and right edges as the lid folds. `sideVoid` scales ONLY
    // that horizontal divergence, so the vertical geometry (recession, blur,
    // void fade) stays identical: 0 keeps the frame at its full width with no
    // side blackout at all, 1 reproduces the physical projection, and >1
    // exaggerates the falloff.
    float sideSpread = 1.0 + (perspective - 1.0) * clamp(u.sideVoid, 0.0, 2.0);
    plane.x = 0.5 + (in.uv.x - 0.5) * sideSpread;
    
    // Defocus blur: smooth progression that remains continuous and silky.
    // Depth-weighted (hinge stays sharper, outer edge falls off) + velocity-aware:
    // fast lid motion adds directional-feel blur via motionBoost, decaying as lid stops.
    float blurSpread = pow(smoothstep(0.0, 0.85, fromHinge), 1.2);
    float motion = smoothstep(0.0, 1.0, turn) * mix(0.20, 1.0, blurSpread);
    float velocityTerm = clamp(u.motionBoost, 0.0, 24.0) * blurSpread;
    float radius = 56.0 * motion * max(0.05, u.blurStrength) + velocityTerm;
    
    // Side margins softness
    float softness = fwidth(in.uv.x) + radius * 0.002;
    float mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.x - 0.5));
    
    // Sample texture using adaptive Vogel disc continuous matte blur
    float3 color = sampleSmoothMatteBlur(tex, s, plane, radius, u.cover, uiPixel, in.position.xy, quality);
    
    // Grazing-angle tint & specular rim. There is NO refraction here: the
    // frozen image is never bent or lensed. `grazingTint` dims the image up
    // to 20% toward the top as the panel tilts (light through glass at a
    // grazing angle); `specularRim` is a Gaussian highlight band centered
    // 65% up from the hinge that strengthens with tilt.
    float grazingTint = sine * pow(fromHinge, 1.5);
    color *= 1.0 - 0.20 * grazingTint;
    float specularRim = exp(-pow((fromHinge - 0.65) / 0.35, 2.0)) * sine;
    color += float3(0.82, 0.85, 0.86) * specularRim * (0.025 * u.reflectionIntensity);

    // Subtle hinge highlight: narrow specular line near the hinge that grows
    // with bend angle. Sells the physical hinge without faking a crease.
    float hingeLine = exp(-pow(fromHinge / 0.06, 2.0)) * sine;
    color += float3(0.90, 0.93, 0.95) * hingeLine * 0.035;
    
    // Smooth void fade: gradual falloff that only fully darkens at the very end
    float fadeDistance = clamp((fromHinge - 0.20) / 0.80, 0.0, 1.0);
    float voidAmount = pow(turn, 1.1) * fadeDistance;
    color *= (1.0 - 0.80 * voidAmount);
    
    // Final closure into deep black right as the lid completely shuts (turn > 0.90)
    float finalClose = 1.0 - smoothstep(0.90, 1.0, turn);
    color *= finalClose;
    
    return float4(mix(DARK, color, mask * finalClose), 1.0);
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant Uniforms &u [[buffer(0)]]) {
    return u.duoMode > 0.5 ? duoFold(in, tex, s, u) : classicFold(in, tex, s, u);
}
