// ============================================================================
// STYX iOS — CODM Garena 1.6.58 offsets (arm64 Mach-O)
// Derived with rodroid il2cpp-dumper-rs v8.0.0 (--codm) from the decrypted IPA.
//
//   Binary   : Payload/codm.app/codm  (Unity + IL2CPP statically linked)
//   Metadata : Data/Managed/Metadata/global-metadata.dat  (v23 CODM variant)
//   CodeRegistration     : 0x10c469b18
//   MetadataRegistration : 0x10c6cabd8
//   Mach-O image base    : 0x100000000  =>  runtime_addr = main_base + RVA
//
// Field offsets are IDENTICAL to the Android GR 1.6.57 build.
// ============================================================================
#pragma once

// ---- function RVAs (hook targets) -----------------------------------------
#define STYX_RVA_Camera_get_main              0x8A50124  // Camera.get_main()                 VA 0x108A50124
#define STYX_RVA_Camera_WorldToScreenPoint    0x8A4FBC4  // Camera.WorldToScreenPoint(Vector3) VA 0x108A4FBC4
#define STYX_RVA_WorldToScreenPoint_static    0x2650FDC  // static WorldToScreenPoint(Vector3) VA 0x102650FDC
#define STYX_RVA_GamePlay_get_MatchGame       0x2390E20  // GamePlay.get_MatchGame()            VA 0x102390E20
#define STYX_RVA_GamePlay_get_LocalPawn       0x2391F14  // GamePlay.get_LocalPawn()            VA 0x102391F14
#define STYX_RVA_Pawn_GetAssitAimSpeed        0x266E378  // PlayerController.GetAssitAimSpeed(Vector3,float,float,float,bool,bool)  VA 0x10266E378 (virtual, Slot 80)
#define STYX_RVA_Pawn_GetScaleRecoil          0x28FBD64  // WeaponFireComponent_Instant.GetScaleRecoil()                 VA 0x1028FBD64
#define STYX_RVA_Pawn_GetRealSpreadModifier   0x28FA2D8  // WeaponFireComponent_Instant.GetRealSpreadModifier()          VA 0x1028FA2D8

// ---- ESP / menu / tutorial / guest-account RVAs (1.6.58 iOS) ---------------
// `static`/`instance` below is taken from dump.cs (authoritative). The dumper's
// script.json "Signature" prepends a phantom `__this` even for static methods
// (e.g. Camera.get_main), so it is NOT a reliable indicator of static-ness.
#define STYX_RVA_GamePlay_get_LocalPC         0x2391DAC  // GamePlay.get_LocalPC()             VA 0x102391DAC  static -> PlayerController*
#define STYX_RVA_BaseGame_GetEnemyPawns       0xF2E810   // BaseGame.GetEnemyPawns()           VA 0x100F2E810  instance -> PawnList*
#define STYX_RVA_Pawn_get_IsAlive             0x186CAC4  // Pawn.get_IsAlive()                 VA 0x10186CAC4  instance -> bool
#define STYX_RVA_Transform_get_position       0x8AB648   // Transform.get_position()           VA 0x1008AB648  instance -> Vector3
#define STYX_RVA_Screen_get_width             0x8A7E27C  // Screen.get_width()                 VA 0x108A7E27C  static -> int32
#define STYX_RVA_Screen_get_height            0x8A7E2F0  // Screen.get_height()                VA 0x108A7E2F0  static -> int32
#define STYX_RVA_MSDKLogin_ResetGuest         0x4099838  // MSDKLogin.ResetGuest()             VA 0x104099838  static -> void
#define STYX_RVA_FrontEndUIScene_DoSomeThingOnUISceneInited          0xB28718  // FrontEndUIScene.DoSomeThingOnUISceneInited()           instance -> void
#define STYX_RVA_FrontEndUIScene_MarkTutorialFinishedFromAppLauncher 0xB297AC  // FrontEndUIScene.MarkTutorialFinishedFromAppLauncher()  instance -> void

// ---- IL2CPP runtime tables / writable data segments ------------------------
// Both registration pointers live in __DATA_CONST (non-executable), so they can
// be read and their pointer tables redirected without touching signed code.
#define STYX_RVA_IL2CPP_CODE_REGISTRATION     0xC469B18  // CodeRegistration*
#define STYX_RVA_IL2CPP_METADATA_REGISTRATION 0xC6CABD8  // MetadataRegistration*

// Main-image data segment layout (see the Mach-O note at the top of the file).
#define STYX_RVA_DATA_CONST  0xC44C000
#define STYX_SIZE_DATA_CONST 0xD30000
#define STYX_RVA_DATA        0xD17C000
#define STYX_SIZE_DATA       0xC60000

// ---- field offsets (same as Android) ---------------------------------------
#define Pawn_m_IsAlive                    0x548
#define Pawn_m_Mesh                       0x628
#define Pawn_m_HeadBone                   0x308
#define Pawn_m_PlayerInfo                 0x5C0
#define Pawn_m_IsBot                      0x5B9
#define Pawn_m_Location                   0x5A4
#define AttackableTarget_m_AttackableInfo 0x78
#define AttackableTarget_m_Health         0x34
#define AttackableTarget_m_MaxHealth      0x38

// !! BaseGame field table is obfuscated as 0xFFFFFFFF in metadata; Android value
// is 0x178 and every other Pawn/AttackableTarget field matched exactly. Confirm
// at runtime before shipping. (Superseded by GetEnemyPawns(); kept for reference.)
#define BaseGame_EnemyPawns               0x178

// ---- il2cpp System.Collections.Generic.List<T> layout ----------------------
// PawnList derives from List<Pawn>, so iterating it means walking these fields.
// VERIFY at runtime: log _size on the first frames (a wrong offset shows up as
// size==0 rather than a fault).
#define IL2CPP_LIST_ITEMS  0x10   // T[]  _items
#define IL2CPP_LIST_SIZE   0x18   // int32 _size
#define IL2CPP_ARRAY_DATA  0x10   // first element of an Il2CppArray
