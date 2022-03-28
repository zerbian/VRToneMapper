using UnityEngine;
using UnityEngine.Serialization;
using UnityEngine.Rendering;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering.HighDefinition;
using System;


[Serializable, VolumeComponentMenu("Post-processing/Custom/VRToneMapper")]
public sealed class VRToneMapper : CustomPostProcessVolumeComponent, IPostProcessComponent
{
    ///<summary>
    /// List of all available Tone Mapping Operators
    ///</summary>
    public enum ToneMappingOperatorType : int
    {
        None,

        [InspectorName("Standard Reinhard")]
        Reinhard,

        [InspectorName("Reinhard with Gaze")]
        ReinhardGaze,

        Debug
    }

    /// <summary>
    /// A <see cref="VolumeParameter"/> that holds a <see cref="TonemappingMode"/> value.
    /// </summary>
    [Serializable]
    public sealed class ToneMappingOperatorTypeParamter : VolumeParameter<ToneMappingOperatorType>
    {
        public ToneMappingOperatorTypeParamter(ToneMappingOperatorType value, bool overrideState = false) : base(value, overrideState) { }
    }

    [Header("Gaze Details")]
    /// <summary>
    /// The gaze position in screenspace. This should be the target for the Eyetracker
    /// </summary>
    [Tooltip("Center point of the gaze point: X")]
    public ClampedFloatParameter m_GazeCenterX = new ClampedFloatParameter(0.1f, 0.0f, 1.0f);
    /// <summary>
    /// The gaze position in screenspace. This should be the target for the Eyetracker
    /// </summary>
    [Tooltip("Center point of the gaze point: Y")]
    public ClampedFloatParameter m_GazeCenterY = new ClampedFloatParameter(0.1f, 0.0f, 1.0f);


    /// <summary>
    /// The area surrounding the gaze point gets weighted with a Gaussian function. The sigma value controls the radius. Number is in pixel space.
    /// </summary>
    [Tooltip("Gaussian function Sigma value")]
    public FloatParameter m_Sigma = new FloatParameter(0.1f);

    [Header("Tonemapping Details")]
    /// <summary>
    /// Different types of tmos
    /// </summary>
    [Tooltip("Type of Tonemapping")]
    public ToneMappingOperatorTypeParamter m_TonemappingType = new ToneMappingOperatorTypeParamter(ToneMappingOperatorType.Reinhard);

    /// <summary>
    /// Scaling of adaptation speed
    /// </summary>
    [Tooltip("Scaling of adaptation speed")]
    public FloatParameter m_AdaptationScale = new FloatParameter(1.0f);

    // TODO: real use cases!
    /// <summary>
    /// 
    /// </summary>
    [Tooltip("")]
    public FloatParameter m_LuminanceKey = new FloatParameter(1.0f);




    /// <summary>
    /// Shows the Gaussian Weight function
    /// </summary>
    [Header("Debugging")]
    [Tooltip("Debug Gaussian Weighting Function")]
    public BoolParameter m_ShowMask = new BoolParameter(false);

    [Tooltip("Parameter for Debugging")]
    public FloatParameter m_DebugParamter = new FloatParameter(0.5f);

    /// <summary>
    /// Reference to the Matrial aka. the ShaderLab / HLSL Shader file
    /// </summary>
    Material m_Material;

    RenderTextureDescriptor m_MippedSourceDescriptor;
    RenderTexture t_MippedSource;

    /// <summary>
    /// Reference to the texture which is used to store information from the last frame
    /// </summary>
    RTHandle m_LuminanceTextureHandle;

    /// <summary>
    /// Store if we are on the first frame to initilize the <see cref="m_LuminanceTextureHandle"/> Texture
    /// </summary>
    private bool m_FirstFrame;

    // <summary>
    /// Utility for using shader pass names inside CommandBuffer.Blit
    /// </summary>
    /// <param name="passName">Name of pass inside the shader</param>
    private int PASS(String passName)
    {
        int pass = m_Material.FindPass(passName);
        if (pass == -1) throw new Exception(passName + " does not exist in the material/shader");
        return pass;
    }

    public bool IsActive()
    {
        return m_Material != null && m_Sigma.value > 0f;
    }

    public override CustomPostProcessInjectionPoint injectionPoint => CustomPostProcessInjectionPoint.BeforePostProcess;

    public override void Setup()
    {
        // find material
        if (Shader.Find("Hidden/Shader/VRToneMapper") != null)
            m_Material = new Material(Shader.Find("Hidden/Shader/VRToneMapper"));

        m_FirstFrame = true;

        // new texture for temopral stuff, GraphicsFormat is rgba 16 bit floats
        m_LuminanceTextureHandle = RTHandles.Alloc(
            1, 1, // size
            TextureXR.slices, dimension: TextureXR.dimension,
            colorFormat: GraphicsFormat.R16G16B16A16_SFloat, useDynamicScale: false,
            enableRandomWrite: true, name: "LuminanceTexture"
        );
    }

    public override void Render(CommandBuffer cmd, HDCamera camera, RTHandle source, RTHandle destination)
    {
        if (m_Material == null)
            return;

        //m_Material.SetFloat("_Intensity", intensity.value);
        m_Material.SetVector("_GazeCenter", new Vector2(m_GazeCenterX.value,m_GazeCenterY.value));
        m_Material.SetFloat("_Sigma", m_Sigma.value);
        m_Material.SetFloat("_AdaptationScale", m_AdaptationScale.value);
        m_Material.SetFloat("_LuminanceKey", m_LuminanceKey.value);
        m_Material.SetFloat("_DebugParamter", m_DebugParamter.value);


        m_Material.SetTexture("_SourceTexture", source);

        //------------SHOW-MASK-PASS---------------------------------------------------------------
        if (m_ShowMask.value)
        {
            cmd.Blit(source, destination, m_Material, PASS("Mask"));
            return;
        }

        //------------GAUSSIAN-PASS----------------------------------------------------------------
        // setup dest texture for gaussian weighting
        m_MippedSourceDescriptor = ((RenderTexture)source).descriptor;
        m_MippedSourceDescriptor.useMipMap = true;
        m_MippedSourceDescriptor.autoGenerateMips = true;
        RenderTexture t_MippedSource = RenderTexture.GetTemporary(m_MippedSourceDescriptor);

        // weight and generate mipMaps
        cmd.Blit(null, t_MippedSource, m_Material, PASS("Weight"));

        //------------COPY-MIP-AND-LUMINANCE-PASS--------------------------------------------------
        // setup values for next pass, maxMip and the mipped-texture
        // luminance pass into separat 1x1 texture, update luminance
        int maxMip = t_MippedSource.mipmapCount - 1;
        m_Material.SetInteger("_MaxMipLevel", maxMip);
        m_Material.SetTexture("_MippedTexture", t_MippedSource);

        if (m_FirstFrame)
        {
            Debug.Log("First Frame");
            m_FirstFrame = false;
            cmd.Blit(null, m_LuminanceTextureHandle, m_Material, PASS("Init"));
            return;
        }

        RenderTexture t_Texture = RenderTexture.GetTemporary(((RenderTexture)m_LuminanceTextureHandle).descriptor);
        m_Material.SetTexture("_LuminanceTexture", m_LuminanceTextureHandle);
        cmd.Blit(null, t_Texture, m_Material, PASS("Luminance"));
        cmd.CopyTexture(t_Texture, m_LuminanceTextureHandle);

        RenderTexture.ReleaseTemporary(t_Texture);

        //------------FINAL-SCALE-PASS-------------------------------------------------------------
        m_Material.SetTexture("_LuminanceTexture", m_LuminanceTextureHandle);
        cmd.Blit(null, destination, m_Material, PASS(m_TonemappingType.value.ToString())); //


        //------------CLEANUP---------------------------------------------------------------------- 
        RenderTexture.ReleaseTemporary(t_MippedSource);
    }

    public override void Cleanup()
    {
        RTHandles.Release(m_LuminanceTextureHandle);

        CoreUtils.Destroy(m_Material);
    }

}
