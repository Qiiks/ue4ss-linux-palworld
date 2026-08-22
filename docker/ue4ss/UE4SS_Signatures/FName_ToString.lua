-- FName::ToString(FString&) for Palworld Linux (UE 5.1, Steam buildid 24575149)
-- RE-verified 2026-08-22 via the fork's resolved Conv_NameToString UFunction
-- (Func member @ 0xa4e7f00 -> native impl -> FName::ToString 0x794e6e0).
-- Prologue + FName-table lookup + append helper (0x779d9a0) verified by disasm.
-- The old build (24466863) had it at 0x7945dd0; the address is now
-- prologue-validated by the fork before assignment, so a stale value degrades
-- to the AOB/dlsym/Conv fallback instead of SIGSEGV-flooding init.
return 0x794e6e0
