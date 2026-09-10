#include <metal_stdlib>
using namespace metal;

constant float BLUR = 0.0315;
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

inline float3 sampleImage(texture2d<float> tex, sampler s, float2 uv, float sigma, float2 cover) {
    float2 tuv = (uv - 0.5) * cover + 0.5;
    float lod = max(0.0, log2(max(sigma, 1.0)));
    float3 blurred = tex.sample(s, tuv, level(max(1.0, lod))).rgb;
    if (sigma >= 2.0) {
        return blurred;
    }
    float3 sharp = tex.sample(s, tuv, level(0.0)).rgb;
    return mix(sharp, blurred, smoothstep(0.0, 2.0, sigma));
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant Uniforms &u [[buffer(0)]]) {
    float turn = clamp(u.turn, 0.0, 1.0);
    if (turn <= 0.00001) {
        return float4(sampleImage(tex, s, in.uv, 0.0, u.cover), 1.0);
    }
    
    // Up-to-Down Clamshell Fold: Hinge is at the bottom edge (in.uv.y = 1.0)
    float fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
    
    // Scale bend smoothly across the ENTIRE 0.0 -> 1.0 closing turn
    // (Never clamps prematurely at 50%)
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
    
    // Defocus blur from mip chain: develops smoothly as turn progresses
    float blurAngle = pow(turn, 0.7);
    float blurSpread = pow(smoothstep(0.0, 0.85, fromHinge), 1.3);
    float defocus = blurAngle * mix(0.15, 1.0, blurSpread);
    float sigma = u.imageSize.y * BLUR * defocus * u.blurStrength;
    
    // Side margins softness
    float softness = fwidth(in.uv.x) + 2.0 * sigma / max(1.0, u.imageSize.x);
    float mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.x - 0.5));
    
    // Sample texture
    float3 color = sampleImage(tex, s, plane, sigma, u.cover);
    
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

// Gaussian Mip Blur (5-tap separable filter)
struct GaussUniforms {
    float2 step;
    float level;
};

fragment float4 gaussFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant GaussUniforms &u [[buffer(0)]]) {
    float4 color = tex.sample(s, in.uv, level(u.level)) * 0.2270270270;
    color += tex.sample(s, in.uv + u.step * 1.3846153846, level(u.level)) * 0.3162162162;
    color += tex.sample(s, in.uv - u.step * 1.3846153846, level(u.level)) * 0.3162162162;
    color += tex.sample(s, in.uv + u.step * 3.2307692308, level(u.level)) * 0.0702702703;
    color += tex.sample(s, in.uv - u.step * 3.2307692308, level(u.level)) * 0.0702702703;
    return color;
}
