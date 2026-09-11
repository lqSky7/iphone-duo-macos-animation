#include <metal_stdlib>
using namespace metal;

// The picture freezes on the plane the display occupied at the start angle.
// Closing the lid turns the glass toward the viewer about the hinge, and each
// pixel shows the frozen picture along a fixed front-view ray: the picture
// holds still in space while the display sweeps through it. The farther the
// glass has swung away from the picture, the deeper the view behind it, so the
// top of the display frosts over first and sinks into a dim glow of scattered
// light, which fades to black by the end angle.

constant float EYE_DISTANCE = 2.6;      // reference viewer on the picture's centre normal, in display heights
constant float SWEEP_KNEE = 0.79;       // 45°: up to here the glass follows the lid exactly
constant float MAX_SWEEP = 1.08;        // 62°: past the knee the glass eases toward this instead of turning edge-on
constant float HAZE_DENSITY = 4.0;      // how quickly depth hides the picture
constant float FROST_PER_DEPTH = 0.06;  // blur radius in picture heights per display height of depth
constant float FADE_START = 0.45;       // fold progress where the whole display starts fading; black at the end angle
constant float CORNER_RADIUS = 0.035;   // rounded top corners of the frozen picture, in display heights
constant float EDGE_SOFTNESS = 2.0;     // picture edge falloff width, relative to the frost radius
constant float GLOW = 0.2;              // share of the picture's light the frosted glass scatters
constant float GLOW_REACH = 0.12;       // how far scattered light spills past the picture edge, in display heights
constant float VIBRANCY = 0.3;          // extra saturation once fully frosted
constant float AMBIENT_LOD = 6.0;       // mip level that supplies the scattered light
constant float SMOKE = 0.22;            // how much the whole glass has dimmed by the knee, like smoked glass
constant float3 VOID_COLOR = float3(0.003, 0.004, 0.005);

constant int FROST_TAPS = 12;
constant float GOLDEN_ANGLE = 2.39996323;

struct Uniforms {
    float2 imageSize;          // texture size in pixels
    float2 cover;              // aspect-fill scale from picture to texture coordinates
    float aspect;              // display width / height
    float turn;                // fold progress: 0 at the start angle, 1 at the end angle
    float sweep;               // radians the lid has turned away from the picture
    float blurStrength;
    float reflectionIntensity;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut foldVertex(uint vid [[vertex_id]]) {
    // One oversized triangle covers the viewport without a diagonal seam.
    float2 pos = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    VertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    // UV origin: (0,0) at top-left, (1,1) at bottom-right
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return out;
}

// Interleaved gradient noise: a stable per-pixel value in [0, 1).
inline float gradientNoise(float2 pixel) {
    return fract(52.9829189 * fract(dot(pixel, float2(0.06711056, 0.00583715))));
}

// Texture coordinates for a picture position, clamped to the picture.
inline float2 textureUV(float2 uv, float2 cover) {
    return (saturate(uv) - 0.5) * cover + 0.5;
}

// Signed distance to the frozen picture in display heights: rounded top corners,
// square bottom corners along the hinge.
inline float pictureDistance(float2 hit, float aspect, float radius) {
    float2 p = hit - float2(0.0, 0.5);
    float r = p.y > 0.0 ? radius : 0.0;
    float2 q = abs(p) - float2(0.5 * aspect, 0.5) + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

fragment float4 foldFragment(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant Uniforms &u [[buffer(0)]]) {
    if (u.turn <= 0.0 && u.sweep <= 0.0) {
        return float4(tex.sample(s, (in.uv - 0.5) * u.cover + 0.5, level(0.0)).rgb, 1.0);
    }

    // Near edge-on the whole display would map onto a sliver of the picture, so ease off past the knee.
    float sweep = max(u.sweep, 0.0);
    if (sweep > SWEEP_KNEE) {
        float span = MAX_SWEEP - SWEEP_KNEE;
        sweep = SWEEP_KNEE + span * (1.0 - exp((SWEEP_KNEE - sweep) / span));
    }
    float height = 1.0 - in.uv.y;   // 0 at the hinge, 1 at the top edge

    // Glass position in picture space (display heights): x across, y up the picture, z toward the viewer.
    float3 glass = float3((in.uv.x - 0.5) * u.aspect, height * cos(sweep), height * sin(sweep));

    // Follow the fixed front-view ray through the glass back to the picture plane (z = 0).
    const float3 eye = float3(0.0, 0.5, EYE_DISTANCE);
    float2 hit = eye.xy + (glass.xy - eye.xy) * (eye.z / (eye.z - glass.z));
    float2 uv = float2(hit.x / u.aspect + 0.5, 1.0 - hit.y);

    // Screen-space footprint, measured before any early exit.
    float2 texels = u.imageSize * u.cover;
    float2 dx = dfdx(uv) * texels;
    float2 dy = dfdy(uv) * texels;
    float baseLod = max(0.0, 0.5 * log2(max(dot(dx, dx), dot(dy, dy))));
    float pixelSpan = max(max(fwidth(hit.x), fwidth(hit.y)), 1e-5);

    float closing = 1.0 - smoothstep(FADE_START, 1.0, saturate(u.turn));
    if (closing < 0.004) {
        return float4(VOID_COLOR, 1.0);
    }

    float depth = glass.z;
    float radius = u.blurStrength * FROST_PER_DEPTH * depth * texels.y;   // in texels
    float2 center = textureUV(uv, u.cover);

    // Soft, rounded picture edge; the falloff widens with the frost and stays outside the picture.
    float corner = CORNER_RADIUS * smoothstep(0.0, 0.35, sweep);
    float edge = pictureDistance(hit, u.aspect, corner);
    float softness = max(pixelSpan, EDGE_SOFTNESS * radius / texels.y);
    float coverage = 1.0 - smoothstep(0.0, softness, edge);
    float visible = coverage * exp(-HAZE_DENSITY * depth * depth);

    // Frosted glass scatters some of the picture's light where the picture itself is hidden.
    float3 ambient = tex.sample(s, center, level(AMBIENT_LOD)).rgb;
    float3 color = ambient * (GLOW * exp(-max(edge, 0.0) / GLOW_REACH));

    if (visible > 0.004) {
        float3 picture;
        if (radius < 0.5) {
            picture = tex.sample(s, center, level(baseLod)).rgb;
        } else {
            // Vogel disc averaged in roughly linear light, so bright details bloom instead of greying out.
            float lod = max(baseLod, log2(radius * 0.5));
            float2 reach = radius / texels;
            float spin = 6.2831853 * gradientNoise(in.position.xy);
            float3 sum = 0.0;
            float weight = 0.0;
            for (int i = 0; i < FROST_TAPS; i++) {
                float r = sqrt((float(i) + 0.5) / float(FROST_TAPS));
                float a = float(i) * GOLDEN_ANGLE + spin;
                float w = exp(-2.0 * r * r);
                float3 tap = tex.sample(s, textureUV(uv + float2(cos(a), sin(a)) * (r * reach), u.cover), level(lod)).rgb;
                sum += tap * tap * w;
                weight += w;
            }
            picture = sqrt(sum / weight);
            float luma = dot(picture, float3(0.2126, 0.7152, 0.0722));
            picture = saturate(mix(float3(luma), picture, 1.0 + VIBRANCY * saturate(radius / 24.0)));
        }
        color = mix(color, picture * (1.0 - SMOKE * smoothstep(0.0, SWEEP_KNEE, sweep)), visible);
    }

    // A soft reflection band drifts down the glass as it tilts.
    float lift = sin(sweep);
    float band = exp(-pow((height - 0.85 + 0.5 * lift) / 0.28, 2.0));
    float3 sheen = float3(0.82, 0.85, 0.86) * (band * lift * 0.035 * u.reflectionIntensity);

    float3 result = (color + sheen) * closing;
    result += (gradientNoise(in.position.xy + 61.0) - 0.5) / 255.0;   // dither the long dark ramp
    return float4(result, 1.0);
}
