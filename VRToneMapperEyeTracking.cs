using System.Collections;
using System.Collections.Generic;

using UnityEngine.Rendering;
using UnityEngine.Rendering.HighDefinition;
using UnityEngine;


public class VRToneMapperEyeTracking : MonoBehaviour
{
    public Volume m_Volume;

    private VRToneMapper m_VRTM;

    // Start is called before the first frame update
    void Start()
    {
        VolumeProfile profile = m_Volume.sharedProfile;

        if (!profile.TryGet<VRToneMapper>(out var vrtm))
        {
            Debug.Log("Cannot find Tonemapper");
        }
        this.m_VRTM = vrtm;

        m_VRTM.m_GazeCenterX.value = 0.5f;
        m_VRTM.m_GazeCenterY.value = 0.5f;

    }


    // Update is called once per frame
    void Update()
    {
        // paste code for eyetracking update here
        m_VRTM.m_GazeCenterX.value = (float)Mathf.Sin(Time.realtimeSinceStartup * 0.5f) * 0.5f + 0.5f; 
    }
}
