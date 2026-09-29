#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

struct ViewInfo
{
    float4 camera_forward;
};

struct RadianceLayoutInfo
{
    float mip_layout;
};

struct DebugViewInfo
{
    float4 view;
};

struct FogInfo
{
    float4 params0;
    float4 params1;
    float4 params2;
    float4 color;
    float4 sun;
    float4 sun_dir;
};

struct FragInfo
{
    float4 color;
    float4 emissive_factor;
    float4 punctual_dims;
    float4 spot_shadow_params;
    float4 scene_inputs;
    float4 camera_forward;
    float4 camera_right;
    float4 camera_up;
    float4 probe_box;
    float4 probe_extents;
    float4 directional_light_direction;
    float4 directional_light_color;
    float4x4 light_space_matrix[4];
    float4 cascade_box_sizes;
    float vertex_color_weight;
    float metallic_factor;
    float has_normal_map;
    float occlusion_strength;
    float environment_intensity;
    float has_directional_light;
    float casts_shadow;
    float shadow_bias;
    float shadow_normal_bias;
    float shadow_texel_size;
    float alpha_mode;
    float alpha_cutoff;
    float shadow_fade;
    float shadow_softness;
    float shadow_cascade_count;
    float specular_aa_variance;
    float specular_aa_threshold;
    float4x4 environment_transform;
    float4 ssao_params;
    float4 radiance_blend;
    float4 ssao_lighting;
    float4 dielectric_f0;
    float4 gi_grid;
    float4 gi_anchor;
    float4 gi_counts;
    float4 gi_atlas;
    float4 gi_visibility;
    float4 froxel_grid;
    float4 view_projection;
    float4 camera_position;
};

struct TextureTransforms
{
    float4 base_color_transform;
    float4 base_color_rotation;
    float4 metallic_roughness_transform;
    float4 metallic_roughness_rotation;
    float4 normal_transform;
    float4 normal_rotation;
    float4 emissive_transform;
    float4 emissive_rotation;
    float4 occlusion_transform;
    float4 occlusion_rotation;
};

struct flutter_scene_standard_fragment_main_out
{
    float4 frag_color [[color(0)]];
};

struct flutter_scene_standard_fragment_main_in
{
    float3 v_position [[user(locn0)]];
    float3 v_normal [[user(locn1)]];
    float3 v_viewvector [[user(locn2)]];
    float2 v_texture_coords [[user(locn3)]];
    float2 v_texture_coords_1 [[user(locn4)]];
    float4 v_color [[user(locn5)]];
    float4 v_tangent [[user(locn6)]];
};

fragment flutter_scene_standard_fragment_main_out flutter_scene_standard_fragment_main(flutter_scene_standard_fragment_main_in in [[stage_in]], constant ViewInfo& view_info [[buffer(0)]], constant RadianceLayoutInfo& radiance_layout_info [[buffer(1)]], constant DebugViewInfo& debug_view_info [[buffer(2)]], constant FogInfo& fog [[buffer(3)]], constant FragInfo& frag_info [[buffer(4)]], constant TextureTransforms& texture_transforms [[buffer(5)]], texture2d<float> irradiance_field [[texture(0)]], texture2d<float> shadow_map [[texture(1)]], texture2d<float> punctual_lights [[texture(2)]], texture2d<float> punctual_index [[texture(3)]], texture2d<float> ssao_texture [[texture(4)]], texture2d<float> prefiltered_radiance [[texture(5)]], texture2d<float> prefiltered_radiance_b [[texture(6)]], texture2d<float> brdf_lut [[texture(7)]], texture2d<float> base_color_texture [[texture(8)]], texture2d<float> normal_texture [[texture(9)]], texture2d<float> metallic_roughness_texture [[texture(10)]], texture2d<float> occlusion_texture [[texture(11)]], texture2d<float> emissive_texture [[texture(12)]], sampler irradiance_fieldSmplr [[sampler(0)]], sampler shadow_mapSmplr [[sampler(1)]], sampler punctual_lightsSmplr [[sampler(2)]], sampler punctual_indexSmplr [[sampler(3)]], sampler ssao_textureSmplr [[sampler(4)]], sampler prefiltered_radianceSmplr [[sampler(5)]], sampler prefiltered_radiance_bSmplr [[sampler(6)]], sampler brdf_lutSmplr [[sampler(7)]], sampler base_color_textureSmplr [[sampler(8)]], sampler normal_textureSmplr [[sampler(9)]], sampler metallic_roughness_textureSmplr [[sampler(10)]], sampler occlusion_textureSmplr [[sampler(11)]], sampler emissive_textureSmplr [[sampler(12)]], bool gl_FrontFacing [[front_facing]], float4 gl_FragCoord [[position]])
{
    flutter_scene_standard_fragment_main_out out = {};
    float3 _6931 = fast::normalize(in.v_normal);
    float3 _6933 = _6931 * (gl_FrontFacing ? 1.0 : (-1.0));
    float4 _6974 = mix(float4(1.0), in.v_color, float4(frag_info.vertex_color_weight));
    bool _6977 = texture_transforms.base_color_rotation.w > 0.5;
    float2 _40227;
    if (_6977)
    {
        float2 _40226;
        if (int(texture_transforms.base_color_rotation.z + 0.5) == 1)
            _40226 = in.v_texture_coords_1;
        else
            _40226 = in.v_texture_coords;
        float2 _7171 = _40226 * texture_transforms.base_color_transform.zw;
        float _7177 = _7171.x;
        float _7182 = _7171.y;
        _40227 = texture_transforms.base_color_transform.xy + float2((texture_transforms.base_color_rotation.x * _7177) - (texture_transforms.base_color_rotation.y * _7182), (texture_transforms.base_color_rotation.y * _7177) + (texture_transforms.base_color_rotation.x * _7182));
    }
    else
    {
    }
    float4 _6991 = base_color_texture.sample(base_color_textureSmplr, _40227);
    float3 _6993 = _6991.xyz;
    float3 _7001 = (mix(_6993 * float3(0.077399380505084991455078125), powr((_6993 + float3(0.054999999701976776123046875)) * float3(0.947867333889007568359375), float3(2.400000095367431640625)), step(float3(0.040449999272823333740234375), _6993)) * _6974.xyz) * frag_info.color.xyz;
    float _7009 = float(0);
    bool _7012 = frag_info.alpha_mode == 1.0;
        if (_7009 < frag_info.alpha_cutoff)
            discard_fragment();
    float _44053 = _7012 ? 1.0 : _7009;
    float _7023 = _7001.x;
    float _7024 = _7001.y;
    float _7025 = _7001.z;
    float4 _7026 = float4(_7023, _7024, _7025, _44053);
    float3 _40239;
    if (frag_info.has_normal_map > 0.5)
    {
        float2 _40230;
        if (_6977)
        {
            float2 _40229;
            if (int(texture_transforms.normal_rotation.z + 0.5) == 1)
                _40229 = in.v_texture_coords_1;
            else
                _40229 = in.v_texture_coords;
            float2 _7265 = _40229 * texture_transforms.normal_transform.zw;
            float _7271 = _7265.x;
            float _7276 = _7265.y;
            _40230 = texture_transforms.normal_transform.xy + float2((texture_transforms.normal_rotation.x * _7271) - (texture_transforms.normal_rotation.y * _7276), (texture_transforms.normal_rotation.y * _7271) + (texture_transforms.normal_rotation.x * _7276));
        }
        else
            _40230 = in.v_texture_coords;
        float3 _7323 = ((normal_texture.sample(normal_textureSmplr, _40230).xyz * 255.0) * float3(0.0078740157186985015869140625)) - float3(1.007874011993408203125);
        float3 _38776 = _7323;
        float3x3 _40238;
            float3 _7386 = float3(0);
            _40238 = float3x3(_7386, fast::normalize(cross(_6933, _7386)) * sign(in.v_tangent.w), _6933);
        _40239 = fast::normalize(_40238 * _38776);
    }
    else
    {
    }
    float2 _40241;
    if (_6977)
    {
        float2 _40240;
        if (int(texture_transforms.metallic_roughness_rotation.z + 0.5) == 1)
            _40240 = in.v_texture_coords_1;
        else
            _40240 = in.v_texture_coords;
        float2 _7541 = _40240 * texture_transforms.metallic_roughness_transform.zw;
        float _7547 = _7541.x;
        float _7552 = _7541.y;
        _40241 = texture_transforms.metallic_roughness_transform.xy + float2((texture_transforms.metallic_roughness_rotation.x * _7547) - (texture_transforms.metallic_roughness_rotation.y * _7552), (texture_transforms.metallic_roughness_rotation.y * _7547) + (texture_transforms.metallic_roughness_rotation.x * _7552));
    }
    else
    {
    }
    float4 _7066 = metallic_roughness_texture.sample(metallic_roughness_textureSmplr, _40241);
    float _7072 = fast::clamp(_7066.z * frag_info.metallic_factor, 0.0, 1.0);
    float _7079 = float(0);
    float2 _40243;
    if (_6977)
    {
        float2 _40242;
        if (int(texture_transforms.occlusion_rotation.z + 0.5) == 1)
            _40242 = in.v_texture_coords_1;
        else
            _40242 = in.v_texture_coords;
        float2 _7611 = _40242 * texture_transforms.occlusion_transform.zw;
        float _7617 = _7611.x;
        float _7622 = _7611.y;
        _40243 = texture_transforms.occlusion_transform.xy + float2((texture_transforms.occlusion_rotation.x * _7617) - (texture_transforms.occlusion_rotation.y * _7622), (texture_transforms.occlusion_rotation.y * _7617) + (texture_transforms.occlusion_rotation.x * _7622));
    }
    else
    {
    }
    float4 _7094 = occlusion_texture.sample(occlusion_textureSmplr, _40243);
    float _7101 = 1.0 - ((1.0 - _7094.x) * frag_info.occlusion_strength);
    float2 _40245;
    if (_6977)
    {
        float2 _40244;
        if (int(texture_transforms.emissive_rotation.z + 0.5) == 1)
            _40244 = in.v_texture_coords_1;
        else
            _40244 = in.v_texture_coords;
        float2 _7681 = _40244 * texture_transforms.emissive_transform.zw;
        float _7687 = _7681.x;
        float _7692 = _7681.y;
        _40245 = texture_transforms.emissive_transform.xy + float2((texture_transforms.emissive_rotation.x * _7687) - (texture_transforms.emissive_rotation.y * _7692), (texture_transforms.emissive_rotation.y * _7687) + (texture_transforms.emissive_rotation.x * _7692));
    }
    else
    {
    }
    float _7733;
    float4 _7116 = emissive_texture.sample(emissive_textureSmplr, _40245);
    float3 _7117 = _7116.xyz;
    float3 _7125 = (mix(_7117 * float3(0.077399380505084991455078125), powr((_7117 + float3(0.054999999701976776123046875)) * float3(0.947867333889007568359375), float3(2.400000095367431640625)), step(float3(0.040449999272823333740234375), _7117)) * frag_info.emissive_factor.xyz) * frag_info.emissive_factor.w;
    float _40275;
        _7733 = debug_view_info.view.x;
        if (_7733 < 0.5)
        _40275 = (debug_view_info.view.y < 0.0) ? 1.0 : 2.0;
    if (_40275 > 1.5)
    {
        float4 _41812;
        float3 _9646 = _7026.xyz;
        float _42381;
            float3 _10435 = float3(0);
            float3 _10437 = float3(0);
            _42381 = sqrt(fast::clamp((_7079 * _7079) + fast::min(2.0 * (frag_info.specular_aa_variance * fast::max(dot(_10435, _10435), dot(_10437, _10437))), frag_info.specular_aa_threshold), 0.00202500005252659320831298828125, 1.0));
        float _42669;
        float4 _43045;
        float3 _43196;
        if (frag_info.ssao_params.x > 0.5)
        {
            float4 _9673 = ssao_texture.sample(ssao_textureSmplr, (gl_FragCoord.xy * frag_info.ssao_params.zw));
            float _42382;
            float _9686 = fast::min(_7101, _42382);
            float3 _9723 = float3(0);
            _43196 = mix(_9723, fast::max(_9723, ((((((_9646 * 2.040400028228759765625) - float3(0.3323999941349029541015625)) * _9686) + ((_9646 * (-4.79510021209716796875)) + float3(0.6417000293731689453125))) * _9686) + ((_9646 * 2.755199909210205078125) + float3(0.69029998779296875))) * _9686), float3(fast::clamp(frag_info.ssao_lighting.y, 0.0, 1.0)));
            _43045 = _9673;
        }
        else
            _42669 = _7101;
        bool _10553 = view_info.camera_forward.w > 0.5;
        float3 _42389;
        if (_10553)
            _42389 = -view_info.camera_forward.xyz;
        else
            _42389 = fast::normalize(in.v_viewvector);
        float3 _9741 = float3(0);
        float _9745 = float(0);
        float _9749 = float(0);
        bool _9769 = false;
        float3 _42401;
            float _10877 = float(0);
            float _10881 = float(0);
            float _10883 = float(0);
            float _10902 = float(0);
            _42401 = mix(prefiltered_radiance.sample(prefiltered_radianceSmplr, float2(_10902, (_10883 + _10877) * 0.125)).xyz, prefiltered_radiance.sample(prefiltered_radianceSmplr, float2(_10902, (fast::min(_10883 + 1.0, 7.0) + _10877) * 0.125)).xyz, float3(_10881 - _10883));
        bool _9789 = false;
        float3 _42407;
        if (_9789)
            float3 _9800 = float3(0);
        else
            _42407 = _42401;
        float _11295;
        float3 _9811 = float3(0);
        float _42408;
            _11295 = frag_info.gi_grid.w;
            float3 _11308 = (in.v_position / frag_info.gi_grid.xyz) - frag_info.gi_anchor.xyz;
            float3 _11316 = fast::min(_11308, (frag_info.gi_counts.xyz - float3(1.0)) - _11308);
            _42408 = fast::clamp(fast::min(_11316.x, fast::min(_11316.y, _11316.z)) / fast::max(frag_info.gi_visibility.w, 0.001000000047497451305389404296875), 0.0, 1.0);
        float3 _42599;
        if (_42408 > 0.0)
        {
            float3 _11408 = in.v_position + (((_40239 * 0.20000000298023223876953125) + (_42389 * 0.800000011920928955078125)) * ((0.75 * fast::min(frag_info.gi_grid.x, fast::min(frag_info.gi_grid.y, frag_info.gi_grid.z))) * frag_info.gi_anchor.w));
            float3 _11411 = _11408 / frag_info.gi_grid.xyz;
            float3 _11413 = floor(_11411);
            float3 _11419 = float3(0);
            bool _11552;
            float3 _11555 = float3(0);
            float3 _11559 = fast::max(_11555, float3(0.001000000047497451305389404296875));
            float3 _11720 = _11413 - (frag_info.gi_counts.xyz * floor(_11413 / frag_info.gi_counts.xyz));
            float _11736 = _11720.x + (frag_info.gi_counts.x * (_11720.y + (frag_info.gi_counts.y * _11720.z)));
            bool _11606 = frag_info.gi_visibility.x > 0.0;
            float _42414;
            float _11673 = fast::max(9.9999999747524270787835121154785e-07, _42414);
            float _42415;
            if (_11673 < 0.20000000298023223876953125)
            {
            }
            else
                _42415 = _11673;
            float _11688 = _42415 * (((_11559.x * _11559.y) * _11559.z) * (_11552 ? 0.0 : 1.0));
            float _11847 = floor(_11736 / frag_info.gi_counts.w);
            float2 _11861 = float2((_11736 - (_11847 * frag_info.gi_counts.w)) * 8.0, frag_info.gi_atlas.x + (_11847 * 8.0));
            float2 _42416;
            float3 _11705 = fast::max(irradiance_field.sample(irradiance_fieldSmplr, (fast::clamp((_11861 + float2(1.0)) + (fast::clamp((_42416 * 0.5) + float2(0.5), float2(0.0), float2(1.0)) * 6.0), _11861 + float2(0.5), _11861 + float2(7.5)) * frag_info.gi_atlas.zw)).xyz, float3(0.0)) * _11688;
            float _12132 = float(0);
            float _42424;
            if (_12132 < 0.20000000298023223876953125)
                _42424 = _12132 * ((_12132 * _12132) * 25.0);
            else
                _42424 = _12132;
            float _12147 = float(0);
            float4 _12159 = float4(0);
            float _12606 = float(0);
            float4 _12618 = float4(0);
            float _13050 = float(0);
            float _42442;
            if (_13050 < 0.20000000298023223876953125)
                _42442 = _13050 * ((_13050 * _13050) * 25.0);
            else
                _42442 = _13050;
            float _13065 = float(0);
            float4 _13077 = float4(0);
            float _13524 = float(0);
            float4 _13536 = float4(0);
            float _13968 = float(0);
            float _42460;
            if (_13968 < 0.20000000298023223876953125)
                _42460 = _13968 * ((_13968 * _13968) * 25.0);
            else
                _42460 = _13968;
            float _13983 = float(0);
            float4 _13995 = float4(0);
            float _14442 = float(0);
            float4 _14454 = float4(0);
            float3 _14749 = _11413 + float3(1.0);
            bool _14765;
            float3 _14772 = fast::max(_11419, float3(0.001000000047497451305389404296875));
            float3 _14788 = (_14749 * frag_info.gi_grid.xyz) - _11408;
            float _14790 = length(_14788);
            float3 _42472;
            if (_14790 > 9.9999997473787516355514526367188e-06)
                _42472 = _14788 / float3(_14790);
            else
                _42472 = _40239;
            float _14808 = powr((dot(_42472, _40239) * 0.5) + 0.5, 2.0) + 0.20000000298023223876953125;
            float3 _14933 = _14749 - (frag_info.gi_counts.xyz * floor(_14749 / frag_info.gi_counts.xyz));
            float _14949 = _14933.x + (frag_info.gi_counts.x * (_14933.y + (frag_info.gi_counts.y * _14933.z)));
            float _42477;
            if (_11606)
            {
                float _14957 = floor(_14949 / frag_info.gi_counts.w);
                float2 _14971 = float2((_14949 - (_14957 * frag_info.gi_counts.w)) * 16.0, frag_info.gi_atlas.y + (_14957 * 16.0));
                float2 _42473;
                float4 _14835 = irradiance_field.sample(irradiance_fieldSmplr, (fast::clamp((_14971 + float2(1.0)) + (fast::clamp((_42473 * 0.5) + float2(0.5), float2(0.0), float2(1.0)) * 14.0), _14971 + float2(0.5), _14971 + float2(15.5)) * frag_info.gi_atlas.zw));
                float _14840 = _14835.x * frag_info.gi_visibility.z;
                float _14858 = (_14790 - _14840) - frag_info.gi_visibility.y;
                float _42474;
                if (_14858 <= 0.0)
                _42477 = _14808 * mix(1.0, fast::max(0.0500000007450580596923828125, (_42474 * _42474) * _42474), frag_info.gi_visibility.x);
            }
            else
            {
            }
            float _14886 = fast::max(9.9999999747524270787835121154785e-07, _42477);
            float _42478;
            if (_14886 < 0.20000000298023223876953125)
                _42478 = _14886 * ((_14886 * _14886) * 25.0);
            else
                _42478 = _14886;
            float _14901 = _42478 * (((_14772.x * _14772.y) * _14772.z) * (_14765 ? 0.0 : 1.0));
            float4 _14913 = float4(0);
            float4 _11466 = ((((((float4(_11705, _11688) + float4(fast::max(_12159.xyz, float3(0.0)) * _12147, _12147)) + float4(fast::max(_12618.xyz, float3(0.0)) * _12606, _12606)) + float4(fast::max(_13077.xyz, float3(0.0)) * _13065, _13065)) + float4(fast::max(_13536.xyz, float3(0.0)) * _13524, _13524)) + float4(fast::max(_13995.xyz, float3(0.0)) * _13983, _13983)) + float4(fast::max(_14454.xyz, float3(0.0)) * _14442, _14442)) + float4(fast::max(_14913.xyz, float3(0.0)) * _14901, _14901);
            float3 _42481;
            if (_11466.w > 9.9999999747524270787835121154785e-07)
                _42481 = _11466.xyz / float3(_11466.w);
            else
                _42481 = float3(0.0);
            _42599 = mix(_9811, _42481 * _11295, float3(_42408));
        }
        else
            _42599 = _9811;
        float2 _9837 = float2(0);
        float4 _9839 = brdf_lut.sample(brdf_lutSmplr, float2(_9837.x * 0.3333333432674407958984375, _9837.y));
        float _9843 = _9839.x;
        float _9846 = float(0);
        float3 _9848 = ((_9741 + ((fast::max(float3(1.0 - _42381), _9741) - _9741) * powr(fast::clamp(1.0 - _9749, 0.0, 1.0), 5.0))) * _9843) + float3(_9846);
        float3 _9858 = float3(0);
        float3 _9872 = float3(0);
        float _9875 = 1.0 - _7072;
        float3 _9876 = _9646 * _9875;
        float _43337;
        if ((frag_info.ssao_params.y > 1.5) && _9769)
        {
        }
        else
        {
            float _43338;
            if (frag_info.ssao_params.y > 0.5)
            {
                _43338 = fast::clamp((powr(_9745 + _42669, exp2(((-16.0) * _42381) - 1.0)) - 1.0) + _42669, 0.0, 1.0);
            }
            else
            {
            }
            _43337 = _43338;
        }
        bool _9925 = frag_info.has_directional_light > 0.5;
        float _42791;
        if (_9925)
        {
            float3 _9931 = -fast::normalize(frag_info.directional_light_direction.xyz);
            _42791 = dot(_6933, _9931);
        }
        else
        {
        }
        float _9938 = fast::clamp(_42791 * 6.666666507720947265625, 0.0, 1.0);
        bool _9947;
        if (_9925)
            _9947 = frag_info.casts_shadow > 0.5;
        else
            _9947 = _9925;
        float _43028;
        if (_9947 && (_9938 > 0.0))
        {
            int _15303 = int(frag_info.shadow_cascade_count);
            float _42845;
            float _42885;
            if (true && (_15303 > 0))
                float _42846;
            else
                _42885 = 0.0;
                _42845 = 0.0;
            float _42904;
            float _42944;
            if ((_42845 < 1.0) && (_15303 > 1))
            {
            }
            else
                _42944 = _42885;
                _42904 = _42845;
            float _42963;
            float _43003;
            if ((_42904 < 1.0) && (_15303 > 2))
            {
            }
            else
                _43003 = _42944;
                _42963 = _42904;
            float _43022;
            float _43025;
            if ((_42963 < 1.0) && (_15303 > 3))
            {
                float3 _15650 = float3(0);
                float2 _15655 = float2(0);
                float _15662 = fast::max(frag_info.shadow_softness / frag_info.cascade_box_sizes.w, frag_info.shadow_texel_size);
                bool _15683;
                bool _15692;
                if (!_15683)
                {
                    _15692 = _15655.y > (1.0 - _15662);
                }
                else
                {
                }
                bool _15699;
                if (!_15692)
                    _15699 = _15650.z < 0.0;
                else
                    _15699 = _15692;
                bool _15706;
                if (!_15699)
                    _15706 = _15650.z > 1.0;
                else
                    _15706 = _15699;
                float _43023;
                float _43026;
                if (!_15706)
                {
                    float _42966;
                    float _15715 = fast::min(_42966, 1.0 - _42963);
                    float _43024;
                    float _43027;
                    if (_15715 > 0.0)
                    {
                        float _19432 = float(0);
                        float _19438 = float(0);
                        float _42984;
                        if ((frag_info.directional_light_direction.w > 1.5) && (frag_info.directional_light_direction.w < 2.5))
                        {
                            float _19480 = float(0);
                            float _42976;
                            _42984 = fast::clamp(_19480 * fast::max(_19432 - _42976, 0.0), frag_info.shadow_texel_size, _15662);
                        }
                        else
                            _42984 = _15662;
                        float _42991;
                        if (frag_info.directional_light_direction.w > 2.5)
                        {
                            float2 _19800 = float2(0);
                            float2 _19804 = float2(0);
                            float2 _19805 = fast::clamp(_15655 + (float2(-0.707099974155426025390625) * _42984), _19800, _19804);
                            float2 _19816 = (float2(_19805.x, 1.0 - _19805.y) / _19800) - float2(0.5);
                            float2 _19818 = floor(_19816);
                            float2 _19821 = float2(0);
                            float2 _19826 = (_19818 + float2(0.5)) * frag_info.shadow_texel_size;
                            float2 _19836 = float2((3.0 + _19826.x) * _19438, _19826.y);
                            float2 _19843 = float2(0);
                            float2 _19852 = float2(0);
                            float2 _19860 = float2(0);
                            float _19889 = float(0);
                            float2 _19948 = float2(0);
                            float2 _19963 = float2(0);
                            float _20016 = float(0);
                            float2 _20075 = float2(0);
                            float2 _20090 = float2(0);
                            float _20143 = float(0);
                            float2 _20202 = float2(0);
                            float2 _20217 = float2(0);
                            float _20270 = float(0);
                            float _19567 = ((mix(mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, _19836).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19836 + _19852)).x), _19889), mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19836 + _19860)).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19836 + _19843)).x), _19889), _19821.y) + mix(mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, _19963).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19963 + _19852)).x), _20016), mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19963 + _19860)).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_19963 + _19843)).x), _20016), _19948.y)) + mix(mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, _20090).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20090 + _19852)).x), _20143), mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20090 + _19860)).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20090 + _19843)).x), _20143), _20075.y)) + mix(mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, _20217).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20217 + _19852)).x), _20270), mix(float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20217 + _19860)).x), float(_19432 <= shadow_map.sample(shadow_mapSmplr, (_20217 + _19843)).x), _20270), _20202.y);
                            _42991 = _19567 * 0.25;
                        }
                        else
                        bool _19614 = false;
                        bool _19620;
                        float _42992;
                        if (_19620)
                            float2 _19635 = float2(0);
                        else
                            _42992 = _42991;
                        _43024 = _43003 + (_15715 * _42992);
                    }
                    else
                    _43026 = _43027;
                    _43023 = _43024;
                }
                else
                _43025 = _43026;
                _43022 = _43023;
            }
            else
                _43025 = _42963;
            _43028 = _43022 + (1.0 - _43025);
        }
        else
        {
        }
        bool _9960 = false;
        bool _9966;
        if (_9960)
            _9966 = frag_info.camera_up.w < 0.5;
        else
            _9966 = _9960;
        float _43179;
        if (_9966)
        {
        }
        else
            _43179 = _43028;
        float _9975 = _9938 * _43179;
        float3 _9988 = ((((_9872 + (_9876 * ((float3(1.0) - _9848) + _9872))) * _42599) * _43196) + (((_9848 * (_42407 * frag_info.environment_intensity)) * 1.0) * _43337)) * mix(1.0, _9975, frag_info.radiance_blend.y);
        float3 _43593;
        if (frag_info.camera_up.w > 0.5)
            _43593 = _9988 + ((_43045.xyz * _9876) * _7101);
        else
        float3 _43599;
        float _20658;
        float2 _43498;
            _20658 = frag_info.punctual_dims.x;
                float3 _20670 = in.v_position - frag_info.camera_position.xyz;
                float _20685 = dot(_20670, frag_info.camera_forward.xyz);
                float _20691 = float(0);
                float2 _20794 = (float3(dot(_20670, frag_info.camera_right.xyz), dot(_20670, frag_info.camera_up.xyz), _20691).xy / (fast::max(float2(frag_info.scene_inputs.w, frag_info.camera_forward.w), float2(9.9999999747524270787835121154785e-07)) * mix(_20691, 1.0, frag_info.view_projection.z))) + frag_info.view_projection.xy;
                float _20810 = float(int(((((fast::clamp(floor((log2(fast::max(_20685 + frag_info.view_projection.w, 9.9999997473787516355514526367188e-05)) * frag_info.froxel_grid.w) + frag_info.punctual_dims.w), 0.0, frag_info.froxel_grid.z - 1.0) * frag_info.froxel_grid.y) + fast::clamp(floor((0.5 - (_20794.y * 0.5)) * frag_info.froxel_grid.y), 0.0, frag_info.froxel_grid.y - 1.0)) * frag_info.froxel_grid.x) + fast::clamp(floor(((_20794.x * 0.5) + 0.5) * frag_info.froxel_grid.x), 0.0, frag_info.froxel_grid.x - 1.0)) + 0.5));
                _43498 = float2(punctual_index.sample(punctual_indexSmplr, float2((mod(_20810, frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.y, (floor(_20810 / frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.z)).xy);
        int _10035 = int(_43498.y + 0.5);
        float3 _43597;
        float3 _43985;
        for (int _43499 = 0; _43499 < _10035; _43597 = _43985, _43499++)
        {
            float4 _20863 = float4(0);
            float _20878 = (float(int(_20863.x + 0.5)) + 0.5) / _20658;
            float2 _20879 = float2(0);
            float4 _20882 = punctual_lights.sample(punctual_lightsSmplr, _20879);
            float4 _20901 = punctual_lights.sample(punctual_lightsSmplr, float2(0.1875, _20878));
            float _10053 = _20882.w;
            float3 _10055 = _20901.xyz;
            if (_10053 > 2.5)
            {
                float4 _20939 = punctual_lights.sample(punctual_lightsSmplr, float2(0.4375, _20878));
                float3 _10074 = _20939.xyz * (_20939.w * 0.5);
                float3 _10078 = float3(0);
                float3 _10080 = _10078 - _10074;
                float3 _10086 = float3(0);
                float3 _10098 = float3(0);
                float _10112 = float(0);
                float _10117 = fast::clamp(1.0 - (_10112 * _10112), 0.0, 1.0);
                float4 _10145 = float4(0);
                float3 _20997 = fast::normalize(_42389 - (_40239 * dot(_42389, _40239)));
                float3x3 _21019 = transpose(float3x3(_20997, -cross(_40239, _20997), _40239));
                float3 _21024 = _10080 - in.v_position;
                float3 _21030 = _10086 - in.v_position;
                float3 _21059 = float3(0);
                float _21262 = float(0);
                float3x3 _21322 = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0)) * _21019;
                float3 _21328 = fast::normalize(_21322 * _21024);
                float3 _21334 = fast::normalize(_21322 * _21030);
                float3 _21340 = float3(0);
                float3 _21346 = float3(0);
                float _21375 = float(0);
                float _21391 = float(0);
                float _43717;
                if (_21375 > 0.0)
                {
                }
                else
                    _43717 = (0.5 * rsqrt(fast::max(1.0 - (_21375 * _21375), 1.0000000116860974230803549289703e-07))) - _21391;
                float _21424 = float(0);
                float _21440 = float(0);
                float _43718;
                if (_21424 > 0.0)
                    _43718 = _21440;
                else
                    _43718 = (0.5 * rsqrt(fast::max(1.0 - (_21424 * _21424), 1.0000000116860974230803549289703e-07))) - _21440;
                float _21473 = float(0);
                float _21489 = float(0);
                float _43719;
                if (_21473 > 0.0)
                {
                }
                else
                    _43719 = (0.5 * rsqrt(fast::max(1.0 - (_21473 * _21473), 1.0000000116860974230803549289703e-07))) - _21489;
                float _21522 = float(0);
                float _21538 = float(0);
                float _43720;
                if (_21522 > 0.0)
                    _43720 = _21538;
                else
                    _43720 = (0.5 * rsqrt(fast::max(1.0 - (_21522 * _21522), 1.0000000116860974230803549289703e-07))) - _21538;
                float3 _21361 = (((cross(_21328, _21334) * _43717) + (cross(_21334, _21340) * _43718)) + (cross(_21340, _21346) * _43719)) + (cross(_21346, _21328) * _43720);
                float _21564 = float(0);
                _43985 = _43597 + (((_10055 * (_10117 * _10117)) * step(0.0, dot(cross(_10086 - _10080, _10098 - _10080), in.v_position - _10080))) * (((((_9741 * _10145.x) + (_9858 * _10145.y)) * fast::max(((_21262 * _21262) + _21059.z) / (_21262 + 1.0), 0.0)) * 1.0) + (_9876 * fast::max(((_21564 * _21564) + _21361.z) / (_21564 + 1.0), 0.0))));
            }
            else
            {
            }
        }
        bool _10386;
        float3 _43604;
        if (_10386)
            float3 _43600;
        else
            _43604 = fog.color.xyz;
        float4 _10415 = float4((_43593 + (_43597 * mix(1.0, _42669, fast::clamp(frag_info.ssao_lighting.x, 0.0, 1.0)))) + _7125, 1.0) * _44053;
        float4 _43619;
        do
        {
            int _22866 = int(fog.params0.x + 0.5);
            float _43606;
            if (_10553)
                _43606 = fast::max(dot(-in.v_viewvector, view_info.camera_forward.xyz), 0.0);
            else
                _43606 = length(in.v_viewvector);
            if ((fog.params1.w > 0.0) && (_43606 > fog.params1.w))
                break;
            float _43610;
            if (_22866 == 1)
                _43610 = fast::clamp((_43606 - fog.params1.y) / fast::max(fog.params1.z - fog.params1.y, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
            else
                float _43611;
            float _23021 = fast::min(_43610, fog.params0.z);
            float3 _23034 = mix(fog.color.xyz, _43604, float3(fog.params0.w));
            bool _23037 = fog.sun.w > 0.5;
            bool _23043;
            if (_23037)
                _23043 = fog.params2.z > 0.0;
            else
                _23043 = _23037;
            float3 _43615;
            if (_23043)
            {
                float3 _43612;
                if (_10553)
                _43615 = _23034 + ((fog.sun.xyz * powr(fast::max(dot(-_43612, -fast::normalize(fog.sun_dir.xyz)), 0.0), fog.params2.w)) * fog.params2.z);
            }
            else
                _43615 = _23034;
            float _23072 = _10415.w;
            _43619 = float4(mix(_10415.xyz, _43615 * _23072, float3(_23021)), _23072);
        } while(false);
        out.frag_color = select(_43619, _41812, bool4(gl_FragCoord.x >= debug_view_info.view.y));
    }
    else
        if (_40275 > 0.5)
        {
            float4 _41751;
                    float3 _41738;
                    if (_7733 == 1.0)
                    {
                        float _23514 = length(_6933);
                        float3 _41737;
                        if (_23514 > 9.9999999747524270787835121154785e-07)
                            _41737 = _6933 / float3(_23514);
                        else
                            _41737 = float3(0.0);
                        _41738 = ((_41737 * 0.5) + float3(0.5)) * debug_view_info.view.z;
                    }
                    else
                    {
                    }
                    _41751 = float4(_41738, 1.0);
            out.frag_color = _41751;
        }
        else
        {
            float3 _25021 = float3(0);
            float _40284;
            float _40294;
            float3 _40299;
            float _40572;
            float4 _40948;
            float3 _41099;
            if (frag_info.ssao_params.x > 0.5)
            {
                float4 _25048 = ssao_texture.sample(ssao_textureSmplr, (gl_FragCoord.xy * frag_info.ssao_params.zw));
                float _40285;
                float _25061 = fast::min(_7101, _40285);
                bool _25064 = frag_info.ssao_lighting.z > 0.5;
                bool _25070;
                if (_25064)
                    _25070 = frag_info.camera_up.w < 0.5;
                else
                    _25070 = _25064;
                float3 _40300;
                if (_25070)
                {
                    float2 _25845 = (_25048.zw * 2.0) - float2(1.0);
                    float _25847 = float(0);
                    float _25849 = _25845.y;
                    float _25857 = float(0);
                    float3 _25858 = float3(_25847, _25849, _25857);
                    float3 _40288;
                    if (_25857 < 0.0)
                        float3 _39578 = float3(0);
                    else
                        _40288 = _25858;
                    float3 _25879 = -fast::normalize(_40288);
                    _40300 = fast::normalize(((frag_info.camera_right.xyz * _25879.x) + (frag_info.camera_up.xyz * _25879.y)) + (frag_info.camera_forward.xyz * _25879.z));
                }
                else
                    _40300 = float3(0.0);
                float3 _25098 = float3(0);
                _41099 = mix(_25098, fast::max(_25098, ((((((_25021 * 2.040400028228759765625) - float3(0.3323999941349029541015625)) * _25061) + ((_25021 * (-4.79510021209716796875)) + float3(0.6417000293731689453125))) * _25061) + ((_25021 * 2.755199909210205078125) + float3(0.69029998779296875))) * _25061), float3(fast::clamp(frag_info.ssao_lighting.y, 0.0, 1.0)));
                _40299 = _40300;
                _40294 = float(_25070);
            }
            else
                _40948 = float4(1.0);
                _40572 = _7101;
            bool _25928 = view_info.camera_forward.w > 0.5;
            float3 _40292;
            if (_25928)
                _40292 = -view_info.camera_forward.xyz;
            else
                _40292 = fast::normalize(in.v_viewvector);
            float3 _25116 = mix(frag_info.dielectric_f0.xyz, _25021, float3(_7072));
            float _25120 = float(0);
            float _25124 = float(0);
            float3 _25128 = reflect(-_40292, _40239);
            float3x3 _25141 = float3x3(frag_info.environment_transform[0].xyz, frag_info.environment_transform[1].xyz, frag_info.environment_transform[2].xyz);
            bool _25144 = _40294 > 0.5;
            float3 _40303;
            if (frag_info.probe_box.w > 0.5)
            {
                float3 _25997 = float3(1.0) / (_25128 + (((step(float3(0.0), _25128) * 2.0) - float3(1.0)) * 9.9999999747524270787835121154785e-07));
                float3 _26014 = fast::max(((frag_info.probe_box.xyz + frag_info.probe_extents.xyz) - in.v_position) * _25997, ((frag_info.probe_box.xyz - frag_info.probe_extents.xyz) - in.v_position) * _25997);
                _40303 = fast::normalize((in.v_position + (_25128 * fast::max(fast::min(fast::min(_26014.x, _26014.y), _26014.z), 0.0))) - frag_info.probe_box.xyz);
            }
            else
                _40303 = _25128;
            bool _26242;
            float3 _25154 = _25141 * _40303;
            float3 _40304;
            do
            {
                _26242 = radiance_layout_info.mip_layout > 0.5;
                if (_26242)
                {
                    _40304 = prefiltered_radiance.sample(prefiltered_radianceSmplr, ((float2(precise::atan2(_25154.z, _25154.x), asin(fast::clamp(_25154.y, -1.0, 1.0))) * float2(0.15915493667125701904296875, 0.3183098733425140380859375)) + float2(0.5)), level(fast::clamp(_40284, 0.0, 1.0) * 7.0)).xyz;
                    break;
                }
                float _26252 = float(0);
                float _26256 = fast::clamp(_40284, 0.0, 1.0) * 7.0;
                float _26258 = floor(_26256);
                float _26277 = float(0);
                _40304 = mix(prefiltered_radiance.sample(prefiltered_radianceSmplr, float2(_26277, (_26258 + _26252) * 0.125)).xyz, prefiltered_radiance.sample(prefiltered_radianceSmplr, float2(_26277, (fast::min(_26258 + 1.0, 7.0) + _26252) * 0.125)).xyz, float3(_26256 - _26258));
            } while(false);
            bool _25164 = frag_info.radiance_blend.x > 0.0;
            float3 _40310;
            if (_25164)
            {
                float3 _40305;
                float3 _25175 = float3(0);
                _40310 = mix(_40304, _40305, _25175);
            }
            else
                _40310 = _40304;
            float _26670;
            float3 _25186 = float3(0);
            float _40311;
            do
            {
                _26670 = frag_info.gi_grid.w;
                if (_26670 <= 0.0)
                    break;
                float3 _26683 = (in.v_position / frag_info.gi_grid.xyz) - frag_info.gi_anchor.xyz;
                float3 _26691 = fast::min(_26683, (frag_info.gi_counts.xyz - float3(1.0)) - _26683);
                _40311 = fast::clamp(fast::min(_26691.x, fast::min(_26691.y, _26691.z)) / fast::max(frag_info.gi_visibility.w, 0.001000000047497451305389404296875), 0.0, 1.0);
            } while(false);
            float3 _40502;
            if (_40311 > 0.0)
            {
                float3 _26783 = in.v_position + (((_40239 * 0.20000000298023223876953125) + (_40292 * 0.800000011920928955078125)) * ((0.75 * fast::min(frag_info.gi_grid.x, fast::min(frag_info.gi_grid.y, frag_info.gi_grid.z))) * frag_info.gi_anchor.w));
                float3 _26786 = _26783 / frag_info.gi_grid.xyz;
                float3 _26788 = floor(_26786);
                float3 _26794 = float3(0);
                bool _26927;
                float3 _26930 = float3(0);
                float3 _26934 = fast::max(_26930, float3(0.001000000047497451305389404296875));
                float _26952 = float(0);
                float3 _40312;
                if (_26952 > 9.9999997473787516355514526367188e-06)
                {
                }
                else
                    _40312 = _40239;
                float _26970 = powr((dot(_40312, _40239) * 0.5) + 0.5, 2.0) + 0.20000000298023223876953125;
                float3 _27095 = _26788 - (frag_info.gi_counts.xyz * floor(_26788 / frag_info.gi_counts.xyz));
                float _27111 = _27095.x + (frag_info.gi_counts.x * (_27095.y + (frag_info.gi_counts.y * _27095.z)));
                bool _26981 = frag_info.gi_visibility.x > 0.0;
                float _40317;
                if (_26981)
                {
                    float _27119 = float(0);
                    float2 _27133 = float2((_27111 - (_27119 * frag_info.gi_counts.w)) * 16.0, frag_info.gi_atlas.y + (_27119 * 16.0));
                    float2 _40313;
                    float4 _26997 = irradiance_field.sample(irradiance_fieldSmplr, (fast::clamp((_27133 + float2(1.0)) + (fast::clamp((_40313 * 0.5) + float2(0.5), float2(0.0), float2(1.0)) * 14.0), _27133 + float2(0.5), _27133 + float2(15.5)) * frag_info.gi_atlas.zw));
                    float _27002 = _26997.x * frag_info.gi_visibility.z;
                    float _27020 = (_26952 - _27002) - frag_info.gi_visibility.y;
                    float _40314;
                    if (_27020 <= 0.0)
                        _40314 = 1.0;
                    else
                    _40317 = _26970 * mix(1.0, fast::max(0.0500000007450580596923828125, (_40314 * _40314) * _40314), frag_info.gi_visibility.x);
                }
                else
                    _40317 = _26970;
                float _27048 = fast::max(9.9999999747524270787835121154785e-07, _40317);
                float _40318;
                if (_27048 < 0.20000000298023223876953125)
                    _40318 = _27048 * ((_27048 * _27048) * 25.0);
                else
                    _40318 = _27048;
                float _27063 = _40318 * (((_26934.x * _26934.y) * _26934.z) * (_26927 ? 0.0 : 1.0));
                float2 _27236 = float2(0);
                float2 _40319;
                float3 _27080 = fast::max(irradiance_field.sample(irradiance_fieldSmplr, (fast::clamp((_27236 + float2(1.0)) + (fast::clamp((_40319 * 0.5) + float2(0.5), float2(0.0), float2(1.0)) * 6.0), _27236 + float2(0.5), _27236 + float2(7.5)) * frag_info.gi_atlas.zw)).xyz, float3(0.0)) * _27063;
                float _27522 = float(0);
                float4 _27534 = float4(0);
                float _27966 = float(0);
                float _40336;
                if (_27966 < 0.20000000298023223876953125)
                    _40336 = _27966 * ((_27966 * _27966) * 25.0);
                else
                    _40336 = _27966;
                float _27981 = float(0);
                float4 _27993 = float4(0);
                float _28440 = float(0);
                float4 _28452 = float4(0);
                float _28884 = float(0);
                float _40354;
                if (_28884 < 0.20000000298023223876953125)
                    _40354 = _28884 * ((_28884 * _28884) * 25.0);
                else
                    _40354 = _28884;
                float _28899 = float(0);
                float4 _28911 = float4(0);
                float _29358 = float(0);
                float4 _29370 = float4(0);
                float _29802 = float(0);
                float _40372;
                if (_29802 < 0.20000000298023223876953125)
                    _40372 = _29802 * ((_29802 * _29802) * 25.0);
                else
                    _40372 = _29802;
                float _29817 = float(0);
                float4 _29829 = float4(0);
                float3 _30124 = _26788 + float3(1.0);
                float3 _30129 = _30124 - frag_info.gi_anchor.xyz;
                bool _30132 = false;
                bool _30140;
                if (!_30132)
                {
                    _30140 = any(_30129 >= frag_info.gi_counts.xyz);
                }
                else
                {
                }
                float3 _30147 = fast::max(_26794, float3(0.001000000047497451305389404296875));
                float _40380;
                float _30261 = fast::max(9.9999999747524270787835121154785e-07, _40380);
                float _40381;
                if (_30261 < 0.20000000298023223876953125)
                    _40381 = _30261 * ((_30261 * _30261) * 25.0);
                else
                    _40381 = _30261;
                float _30276 = _40381 * (((_30147.x * _30147.y) * _30147.z) * (_30140 ? 0.0 : 1.0));
                float4 _30288 = float4(0);
                float4 _26841 = ((((((float4(_27080, _27063) + float4(fast::max(_27534.xyz, float3(0.0)) * _27522, _27522)) + float4(fast::max(_27993.xyz, float3(0.0)) * _27981, _27981)) + float4(fast::max(_28452.xyz, float3(0.0)) * _28440, _28440)) + float4(fast::max(_28911.xyz, float3(0.0)) * _28899, _28899)) + float4(fast::max(_29370.xyz, float3(0.0)) * _29358, _29358)) + float4(fast::max(_29829.xyz, float3(0.0)) * _29817, _29817)) + float4(fast::max(_30288.xyz, float3(0.0)) * _30276, _30276);
                float3 _40384;
                if (_26841.w > 9.9999999747524270787835121154785e-07)
                    _40384 = _26841.xyz / float3(_26841.w);
                else
                    _40384 = float3(0.0);
                _40502 = mix(_25186, _40384 * _26670, float3(_40311));
            }
            else
                _40502 = _25186;
            float2 _25212 = float2(0);
            float4 _25214 = brdf_lut.sample(brdf_lutSmplr, float2(_25212.x * 0.3333333432674407958984375, _25212.y));
            float _25218 = _25214.x;
            float _25221 = float(0);
            float3 _25223 = ((_25116 + ((fast::max(float3(1.0 - _40284), _25116) - _25116) * powr(fast::clamp(1.0 - _25124, 0.0, 1.0), 5.0))) * _25218) + float3(_25221);
            float _25229 = 1.0 - (_25218 + _25221);
            float3 _25233 = float3(0);
            float3 _25236 = _25116 + (_25233 * float3(0.0476190485060214996337890625));
            float3 _25247 = ((_25223 * _25229) * _25236) / (float3(1.0) - (_25236 * _25229));
            float3 _25251 = float3(0);
            float _41240;
            if ((frag_info.ssao_params.y > 1.5) && _25144)
            {
                float _30557 = float(0);
                _41240 = 1.0 - smoothstep(0.0, 1.0, fast::clamp(((acos(fast::clamp(dot(_40299, _25128), -1.0, 1.0)) - acos(sqrt(fast::clamp(1.0 - _40572, 0.0, 1.0)))) + _30557) / (2.0 * _30557), 0.0, 1.0));
            }
            else
            {
                float _41241;
                if (frag_info.ssao_params.y > 0.5)
                    _41241 = fast::clamp((powr(_25120 + _40572, exp2(((-16.0) * _40284) - 1.0)) - 1.0) + _40572, 0.0, 1.0);
                else
                    _41241 = _40572;
                _41240 = _41241;
            }
            bool _25300 = frag_info.has_directional_light > 0.5;
            float _40694;
            if (_25300)
            {
                float3 _25306 = -fast::normalize(frag_info.directional_light_direction.xyz);
                _40694 = dot(_6933, _25306);
            }
            else
            {
            }
            float _25313 = fast::clamp(_40694 * 6.666666507720947265625, 0.0, 1.0);
            bool _25322;
            if (_25300)
                _25322 = frag_info.casts_shadow > 0.5;
            else
                _25322 = _25300;
            float _40931;
            if (_25322 && (_25313 > 0.0))
            {
                int _30678 = int(frag_info.shadow_cascade_count);
                float _31130 = float(0);
                float3 _31150 = in.v_position + (_6933 * (frag_info.shadow_normal_bias + (frag_info.shadow_softness * fast::min(sqrt(fast::max(1.0 - _31130, 0.0)) / _31130, 8.0))));
                float _30684 = frag_info.directional_light_color.w * 0.5;
                float _40748;
                float _40788;
                if (true && (_30678 > 0))
                {
                    float4 _30701 = frag_info.light_space_matrix[0] * float4(_31150, 1.0);
                    float3 _30707 = _30701.xyz / float3(_30701.w);
                    float2 _30710 = _30707.xy * 0.5;
                    float2 _30712 = _30710 + float2(0.5);
                    float _30719 = fast::max(frag_info.shadow_softness / frag_info.cascade_box_sizes.x, frag_info.shadow_texel_size);
                    bool _30740;
                    bool _30749;
                    if (!_30740)
                        _30749 = _30712.y > (1.0 - _30719);
                    else
                        _30749 = _30740;
                    bool _30756;
                    if (!_30749)
                        _30756 = _30707.z < 0.0;
                    else
                        _30756 = _30749;
                    bool _30763;
                    if (!_30756)
                        _30763 = _30707.z > 1.0;
                    else
                        _30763 = _30756;
                    float _40749;
                    float _40789;
                    if (!_30763)
                    {
                        float2 _31158 = float2(_30719);
                        float2 _31163 = float2(_30719 + fast::max(_30684, 9.9999997473787516355514526367188e-05));
                        float2 _31171 = float2(0);
                        float2 _31173 = smoothstep(_31158, _31163, _30712) * smoothstep(_31158, _31163, _31171);
                        float _40695;
                        if (_30684 > 0.0)
                            _40695 = _31173.x * _31173.y;
                        else
                            _40695 = 1.0;
                        float _30772 = fast::min(_40695, 1.0);
                        bool _30774 = _30772 > 0.0;
                        float _40790;
                        if (_30774)
                        {
                            float _31285 = _30707.z - (frag_info.shadow_bias / (7.0 * frag_info.cascade_box_sizes.x));
                            float _31291 = 1.0 / (float(_30678) + frag_info.spot_shadow_params.x);
                            float _40713;
                            float _40720;
                            if (frag_info.directional_light_direction.w > 2.5)
                            {
                                float2 _31653 = float2(frag_info.shadow_texel_size);
                                float2 _31657 = float2(1.0 - frag_info.shadow_texel_size);
                                float2 _31658 = fast::clamp(_30712 + (float2(-0.707099974155426025390625) * _40713), _31653, _31657);
                                float2 _31669 = (float2(_31658.x, 1.0 - _31658.y) / _31653) - float2(0.5);
                                float2 _31671 = float2(0);
                                float2 _31674 = _31669 - _31671;
                                float2 _31679 = (_31671 + float2(0.5)) * frag_info.shadow_texel_size;
                                float2 _31689 = float2(_31679.x * _31291, _31679.y);
                                float _31693 = frag_info.shadow_texel_size * _31291;
                                float2 _31696 = float2(_31693, frag_info.shadow_texel_size);
                                float2 _31705 = float2(0);
                                float2 _31713 = float2(0);
                                float _31742 = _31674.x;
                                float2 _31801 = float2(0);
                                float2 _31816 = float2(0);
                                float _31869 = float(0);
                                float2 _31928 = float2(0);
                                float2 _31943 = float2(0);
                                float _31996 = float(0);
                                float2 _32055 = float2(0);
                                float2 _32070 = float2(0);
                                float _32123 = float(0);
                                float _31420 = ((mix(mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, _31689).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31689 + _31705)).x), _31742), mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31689 + _31713)).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31689 + _31696)).x), _31742), _31674.y) + mix(mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, _31816).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31816 + _31705)).x), _31869), mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31816 + _31713)).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31816 + _31696)).x), _31869), _31801.y)) + mix(mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, _31943).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31943 + _31705)).x), _31996), mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31943 + _31713)).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_31943 + _31696)).x), _31996), _31928.y)) + mix(mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, _32070).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_32070 + _31705)).x), _32123), mix(float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_32070 + _31713)).x), float(_31285 <= shadow_map.sample(shadow_mapSmplr, (_32070 + _31696)).x), _32123), _32055.y);
                                _40720 = _31420 * 0.25;
                            }
                            else
                            {
                            }
                            bool _31467 = 0 == (_30678 - 1);
                            bool _31473;
                            if (_31467)
                                _31473 = frag_info.shadow_fade > 0.0;
                            else
                                _31473 = _31467;
                            float _40721;
                            if (_31473)
                            {
                                float2 _31488 = float2(0);
                                _40721 = mix(1.0, _40720, _31488.x * _31488.y);
                            }
                            else
                                _40721 = _40720;
                            _40790 = _30772 * _40721;
                        }
                        else
                        {
                        }
                        _40789 = _40790;
                    }
                    else
                        _40749 = 0.0;
                    _40788 = _40789;
                }
                else
                    _40748 = 0.0;
                float _40807;
                float _40847;
                if ((_40748 < 1.0) && (_30678 > 1))
                    float _40848;
                else
                    _40847 = _40788;
                    _40807 = _40748;
                float _40866;
                float _40906;
                if ((_40807 < 1.0) && (_30678 > 2))
                {
                    float4 _30913 = frag_info.light_space_matrix[2] * float4(_31150, 1.0);
                    float3 _30919 = _30913.xyz / float3(_30913.w);
                    float2 _30922 = _30919.xy * 0.5;
                    float2 _30924 = _30922 + float2(0.5);
                    float _30931 = fast::max(frag_info.shadow_softness / frag_info.cascade_box_sizes.z, frag_info.shadow_texel_size);
                    bool _30952;
                    bool _30961;
                    if (!_30952)
                        _30961 = _30924.y > (1.0 - _30931);
                    else
                        _30961 = _30952;
                    bool _30968;
                    if (!_30961)
                    {
                        _30968 = _30919.z < 0.0;
                    }
                    else
                    {
                    }
                    bool _30975;
                    if (!_30968)
                        _30975 = _30919.z > 1.0;
                    else
                        _30975 = _30968;
                    float _40867;
                    float _40907;
                    if (!_30975)
                    {
                        float2 _33506 = float2(_30931);
                        float2 _33511 = float2(0);
                        float2 _33519 = float2(0);
                        float2 _33521 = smoothstep(_33506, _33511, _30924) * smoothstep(_33506, _33511, _33519);
                        float _40810;
                        if (_30684 > 0.0)
                        {
                            _40810 = _33521.x * _33521.y;
                        }
                        else
                        {
                        }
                        float _30984 = fast::min(_40810, 1.0 - _40807);
                        float _40868;
                        float _40908;
                        if (_30984 > 0.0)
                        {
                            float _33633 = float(0);
                            float _33639 = 1.0 / (float(_30678) + frag_info.spot_shadow_params.x);
                            float _40835;
                            if (frag_info.directional_light_direction.w > 2.5)
                            {
                                float2 _34001 = float2(frag_info.shadow_texel_size);
                                float2 _34006 = float2(0);
                                float2 _34017 = (float2(_34006.x, 1.0 - _34006.y) / _34001) - float2(0.5);
                                float2 _34019 = float2(0);
                                float2 _34022 = _34017 - _34019;
                                float2 _34027 = float2(0);
                                float2 _34037 = float2((2.0 + _34027.x) * _33639, _34027.y);
                                float _34041 = frag_info.shadow_texel_size * _33639;
                                float2 _34044 = float2(_34041, frag_info.shadow_texel_size);
                                float2 _34053 = float2(0);
                                float2 _34061 = float2(0);
                                float _34090 = _34022.x;
                                float2 _34149 = float2(0);
                                float2 _34164 = float2(0);
                                float _34217 = float(0);
                                float2 _34276 = float2(0);
                                float2 _34291 = float2(0);
                                float _34344 = float(0);
                                float2 _34403 = float2(0);
                                float2 _34418 = float2(0);
                                float _34471 = float(0);
                                float _33768 = ((mix(mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, _34037).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34037 + _34053)).x), _34090), mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34037 + _34061)).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34037 + _34044)).x), _34090), _34022.y) + mix(mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, _34164).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34164 + _34053)).x), _34217), mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34164 + _34061)).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34164 + _34044)).x), _34217), _34149.y)) + mix(mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, _34291).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34291 + _34053)).x), _34344), mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34291 + _34061)).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34291 + _34044)).x), _34344), _34276.y)) + mix(mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, _34418).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34418 + _34053)).x), _34471), mix(float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34418 + _34061)).x), float(_33633 <= shadow_map.sample(shadow_mapSmplr, (_34418 + _34044)).x), _34471), _34403.y);
                                _40835 = _33768 * 0.25;
                            }
                            else
                                float _40831;
                            bool _33815 = 2 == (_30678 - 1);
                            bool _33821;
                            if (_33815)
                                _33821 = frag_info.shadow_fade > 0.0;
                            else
                                _33821 = _33815;
                            float _40836;
                            if (_33821)
                            {
                                float2 _33836 = float2(0);
                                _40836 = mix(1.0, _40835, _33836.x * _33836.y);
                            }
                            else
                                _40836 = _40835;
                            _40908 = _40847 + (_30984 * _40836);
                        }
                        else
                            _40868 = _40807;
                        _40907 = _40908;
                    }
                    else
                        _40867 = _40807;
                    _40906 = _40907;
                }
                else
                    _40866 = _40807;
                float _40925;
                float _40928;
                if ((_40866 < 1.0) && (_30678 > 3))
                {
                    float4 _31019 = frag_info.light_space_matrix[3] * float4(_31150, 1.0);
                    float3 _31025 = _31019.xyz / float3(_31019.w);
                    float2 _31028 = _31025.xy * 0.5;
                    float2 _31030 = _31028 + float2(0.5);
                    float _31037 = fast::max(frag_info.shadow_softness / frag_info.cascade_box_sizes.w, frag_info.shadow_texel_size);
                    bool _31058;
                    bool _31067;
                    if (!_31058)
                        _31067 = _31030.y > (1.0 - _31037);
                    else
                        _31067 = _31058;
                    bool _31074;
                    if (!_31067)
                    {
                        _31074 = _31025.z < 0.0;
                    }
                    else
                    {
                    }
                    bool _31081;
                    if (!_31074)
                        _31081 = _31025.z > 1.0;
                    else
                        _31081 = _31074;
                    float _40926;
                    float _40929;
                    if (!_31081)
                    {
                        float2 _34693 = float2(0.5) - _31028;
                        float2 _34695 = float2(0);
                        float _40869;
                        if (_30684 > 0.0)
                            _40869 = _34695.x * _34695.y;
                        else
                            _40869 = 1.0;
                        float _31090 = fast::min(_40869, 1.0 - _40866);
                        float _40927;
                        float _40930;
                        if (_31090 > 0.0)
                        {
                            float _34807 = float(0);
                            float _34813 = 1.0 / (float(_30678) + frag_info.spot_shadow_params.x);
                            float _34834 = float(0);
                            float _34836 = float(0);
                            float _40887;
                            if ((frag_info.directional_light_direction.w > 1.5) && (frag_info.directional_light_direction.w < 2.5))
                            {
                                float _34855 = float(0);
                                float _34860 = float(0);
                                float _40877;
                                float _40878;
                                _40877 = 0.0;
                                float _34882;
                                float _34885;
                                for (int _40876 = 0; _40876 < 9; _40878 = _34882, _40877 = _34885, _40876++)
                                {
                                    float2 _41675;
                                    float2 _35128 = fast::clamp(_31030 + (float2((_41675.x * _34834) - (_41675.y * _34836), (_41675.x * _34836) + (_41675.y * _34834)) * _34860), float2(frag_info.shadow_texel_size), float2(1.0 - frag_info.shadow_texel_size));
                                    float _35137 = _35128.y;
                                    float2 _35138 = float2((3.0 + _35128.x) * _34813, _35137);
                                    float4 _35145 = shadow_map.sample(shadow_mapSmplr, _35138);
                                    float _35146 = _35145.x;
                                    float _34877 = step(_35146, _34807);
                                    _34885 = _40877 + _34877;
                                }
                                float _40879;
                                if (_40877 > 0.0)
                                _40887 = fast::clamp(_34855 * fast::max(_34807 - _40879, 0.0), frag_info.shadow_texel_size, _31037);
                            }
                            else
                                _40887 = _31037;
                            float _40894;
                            if (frag_info.directional_light_direction.w > 2.5)
                            {
                                float2 _35175 = float2(0);
                                float2 _35179 = float2(1.0 - frag_info.shadow_texel_size);
                                float2 _35180 = fast::clamp(_31030 + (float2(-0.707099974155426025390625) * _40887), _35175, _35179);
                                float2 _35191 = (float2(_35180.x, 1.0 - _35180.y) / _35175) - float2(0.5);
                                float2 _35193 = float2(0);
                                float2 _35196 = _35191 - _35193;
                                float2 _35201 = float2(0);
                                float2 _35211 = float2((3.0 + _35201.x) * _34813, _35201.y);
                                float _35215 = frag_info.shadow_texel_size * _34813;
                                float2 _35218 = float2(_35215, frag_info.shadow_texel_size);
                                float2 _35227 = float2(0);
                                float2 _35235 = float2(0);
                                float _35264 = _35196.x;
                                float2 _35323 = float2(0);
                                float2 _35338 = float2(0);
                                float _35391 = float(0);
                                float2 _35450 = float2(0);
                                float2 _35465 = float2(0);
                                float _35518 = float(0);
                                float2 _35577 = float2(0);
                                float2 _35592 = float2(0);
                                float _35645 = float(0);
                                float _34942 = ((mix(mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, _35211).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35211 + _35227)).x), _35264), mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35211 + _35235)).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35211 + _35218)).x), _35264), _35196.y) + mix(mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, _35338).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35338 + _35227)).x), _35391), mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35338 + _35235)).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35338 + _35218)).x), _35391), _35323.y)) + mix(mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, _35465).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35465 + _35227)).x), _35518), mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35465 + _35235)).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35465 + _35218)).x), _35518), _35450.y)) + mix(mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, _35592).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35592 + _35227)).x), _35645), mix(float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35592 + _35235)).x), float(_34807 <= shadow_map.sample(shadow_mapSmplr, (_35592 + _35218)).x), _35645), _35577.y);
                                _40894 = _34942 * 0.25;
                            }
                            else
                            {
                            }
                            bool _34989 = 3 == (_30678 - 1);
                            bool _34995;
                            if (_34989)
                                _34995 = frag_info.shadow_fade > 0.0;
                            else
                                _34995 = _34989;
                            float _40895;
                            if (_34995)
                            {
                                float2 _35002 = float2(frag_info.shadow_fade / frag_info.cascade_box_sizes.w);
                                float2 _35010 = smoothstep(float2(0.0), _35002, _31030) * smoothstep(float2(0.0), _35002, _34693);
                                _40895 = mix(1.0, _40894, _35010.x * _35010.y);
                            }
                            else
                            _40930 = _40866 + _31090;
                            _40927 = _40906 + (_31090 * _40895);
                        }
                        else
                        _40929 = _40930;
                        _40926 = _40927;
                    }
                    else
                    _40928 = _40929;
                    _40925 = _40926;
                }
                else
                    _40928 = _40866;
                _40931 = _40925 + (1.0 - _40928);
            }
            else
                _40931 = 1.0;
            bool _25335 = frag_info.ssao_lighting.w > 0.5;
            bool _25341;
            if (_25335)
            {
                _25341 = frag_info.camera_up.w < 0.5;
            }
            else
            {
            }
            float _41082;
            if (_25341)
                _41082 = fast::min(_40931, _40948.y);
            else
                _41082 = _40931;
            float _25350 = _25313 * _41082;
            float3 _25363 = ((((_25247 + (_25251 * ((float3(1.0) - _25223) + _25247))) * _40502) * _41099) + (((_25223 * (_40310 * frag_info.environment_intensity)) * 1.0) * _41240)) * mix(1.0, _25350, frag_info.radiance_blend.y);
            float3 _41496;
            if (frag_info.camera_up.w > 0.5)
            {
            }
            else
                _41496 = _25363;
            float _36033;
            float2 _41401;
            do
            {
                _36033 = frag_info.punctual_dims.x;
                if (frag_info.froxel_grid.z > 0.5)
                {
                    float3 _36045 = in.v_position - frag_info.camera_position.xyz;
                    float _36060 = float(0);
                    float _36066 = float(0);
                    float2 _36169 = (float3(dot(_36045, frag_info.camera_right.xyz), dot(_36045, frag_info.camera_up.xyz), _36066).xy / (fast::max(float2(frag_info.scene_inputs.w, frag_info.camera_forward.w), float2(9.9999999747524270787835121154785e-07)) * mix(_36066, 1.0, frag_info.view_projection.z))) + frag_info.view_projection.xy;
                    float _36185 = float(int(((((fast::clamp(floor((log2(fast::max(_36060 + frag_info.view_projection.w, 9.9999997473787516355514526367188e-05)) * frag_info.froxel_grid.w) + frag_info.punctual_dims.w), 0.0, frag_info.froxel_grid.z - 1.0) * frag_info.froxel_grid.y) + fast::clamp(floor((0.5 - (_36169.y * 0.5)) * frag_info.froxel_grid.y), 0.0, frag_info.froxel_grid.y - 1.0)) * frag_info.froxel_grid.x) + fast::clamp(floor(((_36169.x * 0.5) + 0.5) * frag_info.froxel_grid.x), 0.0, frag_info.froxel_grid.x - 1.0)) + 0.5));
                    _41401 = float2(punctual_index.sample(punctual_indexSmplr, float2((mod(_36185, frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.y, (floor(_36185 / frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.z)).xy);
                    break;
                }
                _41401 = float2(frag_info.radiance_blend.w, frag_info.radiance_blend.z);
            } while(false);
            int _25410 = int(_41401.y + 0.5);
            float3 _41500;
            float3 _43886;
            for (int _41402 = 0; _41402 < _25410; _41500 = _43886, _41402++)
            {
                float _36220 = float(0);
                float4 _36238 = punctual_index.sample(punctual_indexSmplr, float2((mod(_36220, frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.y, (floor(_36220 / frag_info.punctual_dims.y) + 0.5) / frag_info.punctual_dims.z));
                float _36253 = (float(int(_36238.x + 0.5)) + 0.5) / _36033;
                float2 _36254 = float2(0);
                float4 _36257 = punctual_lights.sample(punctual_lightsSmplr, _36254);
                float4 _36276 = punctual_lights.sample(punctual_lightsSmplr, float2(0.1875, _36253));
                float _25428 = _36257.w;
                float3 _25430 = _36276.xyz;
                if (_25428 > 2.5)
                {
                    float4 _36314 = punctual_lights.sample(punctual_lightsSmplr, float2(0.4375, _36253));
                    float3 _25449 = _36314.xyz * (_36314.w * 0.5);
                    float3 _25453 = float3(0);
                    float3 _25455 = _25453 - _25449;
                    float3 _25461 = float3(0);
                    float3 _25473 = float3(0);
                    float _25487 = float(0);
                    float _25492 = fast::clamp(1.0 - (_25487 * _25487), 0.0, 1.0);
                    float2 _36322 = (fast::clamp(float2(_40284, sqrt(1.0 - _25120)), float2(0.0), float2(1.0)) * 0.984375) + float2(0.0078125);
                    float _36324 = _36322.x;
                    float _36329 = float(0);
                    float4 _25516 = brdf_lut.sample(brdf_lutSmplr, float2((_36324 + 1.0) * 0.3333333432674407958984375, _36329));
                    float4 _25520 = brdf_lut.sample(brdf_lutSmplr, float2((_36324 + 2.0) * 0.3333333432674407958984375, _36329));
                    float3 _36372 = fast::normalize(_40292 - (_40239 * dot(_40292, _40239)));
                    float3x3 _36394 = transpose(float3x3(_36372, -cross(_40239, _36372), _40239));
                    float3x3 _36395 = float3x3(float3(_25516.x, 0.0, _25516.y), float3(0.0, 1.0, 0.0), float3(_25516.z, 0.0, _25516.w)) * _36394;
                    float3 _36399 = _25455 - in.v_position;
                    float3 _36401 = fast::normalize(_36395 * _36399);
                    float3 _36405 = _25461 - in.v_position;
                    float3 _36407 = fast::normalize(_36395 * _36405);
                    float3 _36413 = float3(0);
                    float3 _36419 = float3(0);
                    float _36448 = float(0);
                    float _36464 = float(0);
                    float _41616;
                    if (_36448 > 0.0)
                        _41616 = _36464;
                    else
                        _41616 = (0.5 * rsqrt(fast::max(1.0 - (_36448 * _36448), 1.0000000116860974230803549289703e-07))) - _36464;
                    float _36497 = float(0);
                    float _36513 = float(0);
                    float _41617;
                    if (_36497 > 0.0)
                        _41617 = _36513;
                    else
                        _41617 = (0.5 * rsqrt(fast::max(1.0 - (_36497 * _36497), 1.0000000116860974230803549289703e-07))) - _36513;
                    float _36546 = float(0);
                    float _36562 = float(0);
                    float _41618;
                    if (_36546 > 0.0)
                        _41618 = _36562;
                    else
                        _41618 = (0.5 * rsqrt(fast::max(1.0 - (_36546 * _36546), 1.0000000116860974230803549289703e-07))) - _36562;
                    float _36595 = float(0);
                    float _36611 = float(0);
                    float _41619;
                    if (_36595 > 0.0)
                    {
                    }
                    else
                        _41619 = (0.5 * rsqrt(fast::max(1.0 - (_36595 * _36595), 1.0000000116860974230803549289703e-07))) - _36611;
                    float3 _36434 = (((cross(_36401, _36407) * _41616) + (cross(_36407, _36413) * _41617)) + (cross(_36413, _36419) * _41618)) + (cross(_36419, _36401) * _41619);
                    float _36637 = float(0);
                    float3 _36736 = float3(0);
                    float _36939 = float(0);
                    _43886 = _41500 + (((_25430 * (_25492 * _25492)) * step(0.0, dot(cross(_25461 - _25455, _25473 - _25455), in.v_position - _25455))) * (((((_25116 * _25520.x) + (_25233 * _25520.y)) * fast::max(((_36637 * _36637) + _36434.z) / (_36637 + 1.0), 0.0)) * 1.0) + (_25251 * fast::max(((_36939 * _36939) + _36736.z) / (_36939 + 1.0), 0.0))));
                }
                else
                {
                }
            }
            bool _25755 = fog.params0.y > 0.5;
            bool _25761;
            if (_25755)
                _25761 = fog.params0.w > 0.0;
            else
                _25761 = _25755;
            float3 _41507;
            if (_25761)
            {
                float3 _41506;
                if (_25164)
                _41507 = _41506 * frag_info.environment_intensity;
            }
            else
                _41507 = fog.color.xyz;
            float4 _25790 = float4((_41496 + (_41500 * mix(1.0, _40572, fast::clamp(frag_info.ssao_lighting.x, 0.0, 1.0)))) + _7125, 1.0) * _44053;
            float4 _41522;
            do
            {
                if (fog.params0.y < 0.5)
                    break;
                int _38241 = int(fog.params0.x + 0.5);
                if (_38241 == 0)
                    break;
                float _41509;
                if (_25928)
                    _41509 = fast::max(dot(-in.v_viewvector, view_info.camera_forward.xyz), 0.0);
                else
                    _41509 = length(in.v_viewvector);
                if ((fog.params1.w > 0.0) && (_41509 > fog.params1.w))
                    break;
                float _41513;
                if (_38241 == 1)
                {
                    _41513 = fast::clamp((_41509 - fog.params1.y) / fast::max(fog.params1.z - fog.params1.y, 9.9999997473787516355514526367188e-05), 0.0, 1.0);
                }
                else
                {
                }
                float _38396 = fast::min(_41513, fog.params0.z);
                float3 _38409 = mix(fog.color.xyz, _41507, float3(fog.params0.w));
                bool _38412 = fog.sun.w > 0.5;
                bool _38418;
                if (_38412)
                {
                }
                else
                    _38418 = _38412;
                float3 _41518;
                if (_38418)
                {
                    float3 _41515;
                    if (_25928)
                        _41515 = -view_info.camera_forward.xyz;
                    else
                        _41515 = fast::normalize(in.v_viewvector);
                    _41518 = _38409 + ((fog.sun.xyz * powr(fast::max(dot(-_41515, -fast::normalize(fog.sun_dir.xyz)), 0.0), fog.params2.w)) * fog.params2.z);
                }
                else
                {
                }
                float _38447 = _25790.w;
                _41522 = float4(mix(_25790.xyz, _41518 * _38447, float3(_38396)), _38447);
            } while(false);
            out.frag_color = _41522;
        }
    return out;
}
