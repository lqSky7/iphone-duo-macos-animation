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

inline float3 sampleSmoothMatteBlur(texture2d<float> tex,
                                    sampler s,
                                    float2 uv,
                                    float radius,
                                    float2 cover,
                                    float2 uiPixel,
                                    float2 screenCoord) {
    float2 tuv = (uv - 0.5) * cover + 0.5;
    
    // When radius is near zero, return razor-sharp native Retina sample at level 0
    if (radius <= 0.15) {
        return tex.sample(s, tuv, level(0.0)).rgb;
    }
    
    // CRITICAL FIX FOR PIXELATION:
    // Previously, `lod = log2(radius)` scaled unchecked into levels 4-6 (45x29 texels),
    // causing massive pixel blocks and severe aliasing that worsened with tilt.
    //
    // By keeping the base LOD tightly bounded (capped at 1.85), texels are never larger
    // than 3-4 physical screen pixels. Combined with a dense 32-sample Vogel Disc
    // (Golden Angle spiral) and trilinear filtering, the blur is 100% continuous,
    // velvety, and free of blocky pixelation at all tilt angles.
    float baseLod = clamp(log2(max(1.0, radius * 0.18)), 0.0, 1.85);
    
    // Subtle sub-pixel micro-rotation per screen pixel eliminates ring banding
    // and produces a natural, tactile frosted-glass matte dispersion.
    float rot = (fract(sin(dot(screenCoord, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.35;
    float cosRot = cos(rot);
    float sinRot = sin(rot);
    
    float3 accum = float3(0.0);
    float totalWeight = 0.0;
    
    // 32-sample Vogel Disc (Golden Angle Fermat Spiral)
    constexpr int NUM_SAMPLES = 32;
    constexpr float GOLDEN_ANGLE = 2.39996323; // pi * (3.0 - sqrt(5.0))
    
    for (int i = 0; i < NUM_SAMPLES; i++) {
        float fi = float(i);
        float theta = fi * GOLDEN_ANGLE;
        // Square root progression provides uniform area density across the disc
        float r = sqrt((fi + 0.5) / float(NUM_SAMPLES));
        
        // Direction rotated by micro-jitter
        float uX = cos(theta);
        float uY = sin(theta);
        float dirX = uX * cosRot - uY * sinRot;
        float dirY = uX * sinRot + uY * cosRot;
        
        float2 offset = float2(dirX, dirY) * (r * radius * uiPixel);
        float2 sampleUV = clamp(tuv + offset, 0.0, 1.0);
        
        // Gaussian optical falloff from center of blur disc
        float weight = exp(-2.3 * r * r);
        
        // Center samples draw fine details; perimeter samples blend into smooth mip
        float sampleLod = mix(0.0, baseLod, smoothstep(0.1, 0.85, r));
        
        accum += tex.sample(s, sampleUV, level(sampleLod)).rgb * weight;
        totalWeight += weight;
    }
    
    float3 blurred = accum / totalWeight;
    
    // Soft matte ambient scatter (frosted glass diffusion characteristic)
    float matteScatter = 0.015 * smoothstep(0.0, 20.0, radius);
    blurred = blurred + float3(matteScatter);
    
    // Smooth transition from sharp to matte blur as fold begins
    float3 sharp = tex.sample(s, tuv, level(0.0)).rgb;
    return mix(sharp, blurred, smoothstep(0.0, 2.0, radius));
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant Uniforms &u [[buffer(0)]]) {
    float turn = clamp(u.turn, 0.0, 1.0);
    float2 uiPixel = 2.0 / max(float2(1.0), u.imageSize);
    
    if (turn <= 0.00001) {
        return float4(sampleSmoothMatteBlur(tex, s, in.uv, 0.0, u.cover, uiPixel, in.position.xy), 1.0);
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
    plane.x = 0.5 + (in.uv.x - 0.5) * perspective;
    
    // Defocus blur: smooth progression that remains continuous and silky
    float blurSpread = pow(smoothstep(0.0, 0.85, fromHinge), 1.2);
    float motion = smoothstep(0.0, 1.0, turn) * mix(0.20, 1.0, blurSpread);
    float radius = 56.0 * motion * max(0.05, u.blurStrength);
    
    // Side margins softness
    float softness = fwidth(in.uv.x) + radius * 0.002;
    float mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.x - 0.5));
    
    // Sample texture using 32-sample Vogel disc continuous matte blur
    float3 color = sampleSmoothMatteBlur(tex, s, plane, radius, u.cover, uiPixel, in.position.xy);
    
    // Glass refraction & reflection
    float glass = sine * pow(fromHinge, 1.5);
    color *= 1.0 - 0.20 * glass;
    float reflection = exp(-pow((fromHinge - 0.65) / 0.35, 2.0)) * sine;
    color += float3(0.82, 0.85, 0.86) * reflection * (0.025 * u.reflectionIntensity);
    
    // Smooth void fade: gradual falloff that only fully darkens at the very end
    float fadeDistance = clamp((fromHinge - 0.20) / 0.80, 0.0, 1.0);
    float voidAmount = pow(turn, 1.1) * fadeDistance;
    color *= (1.0 - 0.80 * voidAmount);
    
    // Final closure into deep black right as the lid completely shuts (turn > 0.90)
    float finalClose = 1.0 - smoothstep(0.90, 1.0, turn);
    color *= finalClose;
    
    return float4(mix(DARK, color, mask * finalClose), 1.0);
}
