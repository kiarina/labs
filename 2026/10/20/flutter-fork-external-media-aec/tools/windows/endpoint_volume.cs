using System; using System.Runtime.InteropServices;
public enum Flow {Render,Capture,All}
public enum Role {Console,Multimedia,Communications}
[ComImport,Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class Enumerator{}
[ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnum { int EnumAudioEndpoints(Flow f,int mask,out IntPtr devices); int GetDefaultAudioEndpoint(Flow f,Role r,out IDevice d); }
[ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDevice {int Activate(ref Guid iid,int context,IntPtr p,out IntPtr obj);int OpenPropertyStore(int mode,out IntPtr store);int GetId([MarshalAs(UnmanagedType.LPWStr)]out string id);int GetState(out int state);}
public class AudioDefaults { public static string Get(int flow,int role){IDevice d;int hr=((IEnum)new Enumerator()).GetDefaultAudioEndpoint((Flow)flow,(Role)role,out d);if(hr!=0)return "HRESULT="+hr;string id;d.GetId(out id);return id;} }
[ComImport,Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IVolume {
[PreserveSig]int RegisterControlChangeNotify(IntPtr p);[PreserveSig]int UnregisterControlChangeNotify(IntPtr p);[PreserveSig]int GetChannelCount(out uint n);
[PreserveSig]int SetMasterVolumeLevel(float v,IntPtr c);[PreserveSig]int SetMasterVolumeLevelScalar(float v,IntPtr c);
[PreserveSig]int GetMasterVolumeLevel(out float v);[PreserveSig]int GetMasterVolumeLevelScalar(out float v);
[PreserveSig]int SetChannelVolumeLevel(uint n,float v,IntPtr c);[PreserveSig]int SetChannelVolumeLevelScalar(uint n,float v,IntPtr c);
[PreserveSig]int GetChannelVolumeLevel(uint n,out float v);[PreserveSig]int GetChannelVolumeLevelScalar(uint n,out float v);
[PreserveSig]int SetMute([MarshalAs(UnmanagedType.Bool)]bool m,IntPtr c);[PreserveSig]int GetMute([MarshalAs(UnmanagedType.Bool)]out bool m);
}
public class VolumeRead {public static string Get(int flow){IDevice d;((IEnum)new Enumerator()).GetDefaultAudioEndpoint((Flow)flow,Role.Console,out d);Guid g=new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");IntPtr ptr;int hr=d.Activate(ref g,23,IntPtr.Zero,out ptr);if(ptr==IntPtr.Zero)return "activate="+hr;IVolume v=(IVolume)Marshal.GetObjectForIUnknown(ptr);float scalar,db;bool mute;uint channels;v.GetMasterVolumeLevel(out db);v.GetMasterVolumeLevelScalar(out scalar);v.GetMute(out mute);v.GetChannelCount(out channels);return "flow="+flow+" scalar="+scalar+" dB="+db+" mute="+mute+" channels="+channels;}}