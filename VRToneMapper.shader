Shader "Hidden/Shader/VRToneMapper"
{
    Properties
    {
        // not needed
    }

    HLSLINCLUDE

    //#pragma target 4.5
    #pragma only_renderers d3d11 playstation xboxone xboxseries vulkan metal switch

    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/ShaderLibrary/ShaderVariables.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/PostProcessing/Shaders/FXAA.hlsl"
    #include "Packages/com.unity.render-pipelines.high-definition/Runtime/PostProcessing/Shaders/RTUpscale.hlsl"

    struct Attributes
    {
        uint vertexID : SV_VertexID;
        UNITY_VERTEX_INPUT_INSTANCE_ID
    };

    struct Varyings
    {
        float4 positionCS : SV_POSITION;
        float2 texcoord   : TEXCOORD0;
        UNITY_VERTEX_OUTPUT_STEREO
    };

    Varyings Vert(Attributes input)
    {
        Varyings output;
        UNITY_SETUP_INSTANCE_ID(input);
        UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
        output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
        output.texcoord = GetFullScreenTriangleTexCoord(input.vertexID);
        return output;
    }

    #define FLT_MIN 1.175494351e-38

    #define TAU_ROD 0.4f
    #define TAU_CONE 0.1f
    #define D65COEFF float3(0.2125f, 0.7154f, 0.0721f)

    float2 _GazeCenter;

    int _MaxMipLevel;

    float _LuminanceKey;
    float _Sigma;
    float _AdaptationScale;

    float _DebugParameter;

    TEXTURE2D_X(_SourceTexture);
    TEXTURE2D_X(_MippedTexture);
    TEXTURE2D_X(_LuminanceTexture);

    float Weight(Varyings input)
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float sigma2 = _Sigma * _Sigma;
        float2 C = (input.texcoord - _GazeCenter) * _ScreenParams.xy; // in pixel space
        float p_distance2 = dot(C, C);
        return length(C) < _Sigma; //exp(-0.5f * p_distance2 / sigma2); //1 / (2 * PI * sigma2) for normalize
    }

    float AvgScalingFactor() {
        float r = _Sigma;
        float aAvg = 2.0f * PI * r * r;
        float aScreen = _ScreenParams.x * _ScreenParams.y;
        return aScreen / aAvg;
    }

    float4 WeightProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float3 sourceColor = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;
        float Y = Luminance(sourceColor);
        float weight = Weight(input);
        float adaptLum = log(Y);
        return float4(adaptLum, adaptLum * weight, Y, Y * weight);
    }

        float4 InitLuminanceTexture(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        return LOAD_TEXTURE2D_X_LOD(_MippedTexture, uint2(0, 0), _MaxMipLevel);
    }

    vector TemporalInterpolation(vector curr, vector last) {
        vector sigma = 0.04f / (0.04f + curr); //?
        vector tau = sigma * TAU_ROD + (1.0f - sigma) * TAU_CONE;
        float delta = unity_DeltaTime.x * _AdaptationScale;
        return last + (curr - last) * (1.0f - exp(-delta / tau));
    }

    float4 LuminanceProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float4 currentYs = LOAD_TEXTURE2D_X_LOD(_MippedTexture, uint2(0, 0), _MaxMipLevel);
        float4 lastYs = SAMPLE_TEXTURE2D_X(_LuminanceTexture, s_linear_clamp_sampler, input.texcoord);

        // temoprally interpolate all 4 values: adaptLum, weighted adpaLum, Lum, weightedLum
        float4 sigma = 0.04f / (0.0f + currentYs);
        float4 tau = sigma * TAU_ROD + (1.0f - sigma) * TAU_CONE;
        float delta = unity_DeltaTime.x;

        return lastYs + (currentYs - lastYs) * (1.0f - exp(-delta / tau));
    }
        
    float4 ReinhardProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

        float Y_ = SAMPLE_TEXTURE2D_X(_LuminanceTexture, s_linear_clamp_sampler, uint2(0, 0)).x;
        float3 color = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;

        float key = _LuminanceKey;

        float Y_r = (key * Luminance(color)) / Y_;
        float L = Y_r / (Y_r + 1.0f);

        float weight = L / Luminance(color);
        return float4(weight * color, 1.0f);
    }

    float4 ReinhardGazeProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

        float Y_ = SAMPLE_TEXTURE2D_X(_LuminanceTexture, s_linear_clamp_sampler, uint2(0, 0)).y * AvgScalingFactor();
        float3 color = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;

        float key = _LuminanceKey;

        float Y_r = (key * Luminance(color)) / Y_;
        float L = Y_r / (Y_r + 1.0f);

        float weight = L / Luminance(color);
        return float4(weight * color, 1.0f);
    }

    float4 NoneProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float3 color = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;
        return float4(color, 1.0f);
    }

    float4 MaskProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float3 color = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;
        float w = Weight(input);
        float r = _Sigma;
        float2 C = (input.texcoord - _GazeCenter) * _ScreenParams.xy; // in pixel space
        float d = (length(C) < r + 1.0f) - (length(C) < (r - 1.0f));
        return float4(d.xxx, 1.0);
    }

    float4 DebugProcess(Varyings input) : SV_Target
    {
        UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
        float3 color = SAMPLE_TEXTURE2D_X(_SourceTexture, s_linear_clamp_sampler, input.texcoord).xyz;
        float4 Ys = LOAD_TEXTURE2D_X_LOD(_MippedTexture, uint2(0, 0), _MaxMipLevel);
        float a = abs(log(Luminance(color)) - Ys.y * AvgScalingFactor()) * _DebugParameter;// * AvgScalingFactor());
        float o = abs(Ys.x - log(Ys.z)) * _DebugParameter;
        //float a = abs(Luminance(color)) / Ys.x;
        return float4(o.xxx, 1.0f);
    }

    ENDHLSL

    SubShader
    {
        Pass
        {
            Name "Weight"

            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment WeightProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "Luminance"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment LuminanceProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "Init"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment InitLuminanceTexture
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "Mask"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment MaskProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "Reinhard"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment ReinhardProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "ReinhardGaze"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment ReinhardGazeProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "None"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment NoneProcess
                #pragma vertex Vert
            ENDHLSL
        }

        Pass
        {
            Name "Debug"
            ZWrite Off
            ZTest Always
            Blend Off
            Cull Off

            HLSLPROGRAM
                #pragma fragment DebugProcess
                #pragma vertex Vert
            ENDHLSL

        }
    }

    Fallback Off
}
