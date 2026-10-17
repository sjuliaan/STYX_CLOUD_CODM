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
#define STYX_RVA_Pawn_GetAssitAimSpeed        0x266E378  // Pawn.GetAssitAimSpeed(...)          VA 0x10266E378 (virtual, Slot 80)
#define STYX_RVA_Pawn_GetScaleRecoil          0x28FBD64  // Pawn.GetScaleRecoil()               VA 0x1028FBD64
#define STYX_RVA_Pawn_GetRealSpreadModifier   0x28FA2D8  // Pawn.GetRealSpreadModifier()        VA 0x1028FA2D8

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
// at runtime before shipping.
#define BaseGame_EnemyPawns               0x178
