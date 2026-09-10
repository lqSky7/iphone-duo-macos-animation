#include <metal_stdlib>
using namespace metal;

constant float HALF_PI = 1.570796327;
constant float BLUR = 0.0315;
constant float MAX_TILT = 0.84106867; // acos(1.0 / 1.5)
constant float3 DARK = float3(0.003, 0.004, 0.005);

struct Uniforms {
    float2 imageSize;
    float2 cover;
    float aspect;
    float turn;
    float hinge;
    int mode; // 0: Clamshell (MacBook bottom), 1: Book Left, 2: Book Right
    float blurStrength;
    float reflectionIntensity;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen quad generated directly from vertex id (0..5)
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

// Sampling with Gaussian mip chain
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
    
    float outer = 1.0 - u.hinge;
    float tilt = turn * HALF_PI;
    float bend = min(tilt, MAX_TILT);
    float cosine = cos(bend);
    float sine = sin(bend);
    
    float fromHinge;
    float2 plane;
    float softness;
    float mask;
    
    if (u.mode == 0) {
        // Clamshell mode: Hinge is at the bottom of the MacBook screen (y = 1.0 in UV)
        fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
        float eye = 2.4 * max(1.0 / u.aspect, 1.0);
        float depth = fromHinge * (1.0 / u.aspect) * sine;
        float perspective = eye / (eye - depth);
        
        plane.y = 1.0 - (1.0 - in.uv.y) * cosine * perspective;
        plane.x = 0.5 + (in.uv.x - 0.5) * perspective;
        
        float blurAngle = pow(smoothstep(0.0, HALF_PI, tilt), 0.5);
        float blurSpread = pow(smoothstep(0.0, 0.7, fromHinge), 1.45);
        float defocus = blurAngle * mix(0.18, 1.0, blurSpread);
        float sigma = u.imageSize.y * BLUR * defocus * u.blurStrength;
        
        softness = fwidth(in.uv.x) + 2.0 * sigma / u.imageSize.x;
        mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.x - 0.5));
        
        float3 color = sampleImage(tex, s, plane, sigma, u.cover);
        float glass = sine * pow(fromHinge, 1.6);
        color *= 1.0 - mix(0.28, 0.06, outer) * glass;
        float reflection = exp(-pow((fromHinge - 0.70) / 0.30, 2.0)) * sine;
        color += float3(0.82, 0.85, 0.86) * reflection * (0.025 * u.reflectionIntensity);
        
        float fade = clamp((fromHinge - 0.26) / 0.74, 0.0, 1.0);
        color *= 1.0 - 0.7 * blurAngle * fade;
        
        return float4(mix(DARK, color, mask), 1.0);
    } else {
        // Book fold mode: exact 1:1 iphone-solo fold along left (hinge=0) or right (hinge=1)
        fromHinge = abs(in.uv.x - u.hinge);
        float eye = 2.4 * max(u.aspect, 1.0);
        float depth = fromHinge * u.aspect * sine;
        float perspective = eye / (eye - depth);
        
        plane.x = u.hinge + (in.uv.x - u.hinge) * cosine * perspective;
        plane.y = 0.5 + (in.uv.y - 0.5) * perspective;
        
        float blurAngle = pow(smoothstep(0.0, HALF_PI, tilt), 0.5);
        float blurSpread = pow(smoothstep(0.0, 0.7, fromHinge), 1.45);
        float defocus = blurAngle * mix(0.18, 1.0, blurSpread);
        float sigma = u.imageSize.x * BLUR * defocus * u.blurStrength;
        
        softness = fwidth(in.uv.y) + 2.0 * sigma / u.imageSize.y;
        mask = 1.0 - smoothstep(0.5 - softness, 0.5 + softness, abs(plane.y - 0.5));
        
        float3 color = sampleImage(tex, s, plane, sigma, u.cover);
        float glass = sine * pow(fromHinge, 1.6);
        color *= 1.0 - mix(0.28, 0.06, outer) * glass;
        float reflection = exp(-pow((fromHinge - 0.70) / 0.30, 2.0)) * sine;
        color += float3(0.82, 0.85, 0.86) * reflection * (0.025 * u.reflectionIntensity);
        
        float fade = clamp((fromHinge - 0.26) / 0.74, 0.0, 1.0);
        color *= 1.0 - 0.7 * blurAngle * fade;
        
        return float4(mix(DARK, color, mask), 1.0);
    }
}

// MARK: - Gaussian Mip Blur (5-tap separable filter from iphone-solo GAUSS shader)

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
