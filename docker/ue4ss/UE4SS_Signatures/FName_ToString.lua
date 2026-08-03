-- FName::ToString(FString&) for Palworld Linux (UE 5.1, build 0999680e29)
-- RE-verified live 2026-08-03 via the fork's resolved Conv_NameToString UFunction
-- (Func member @ 0xa4df670 -> Conv impl 0x7945d30 -> FName::ToString 0x7945dd0).
-- Append-into-capacity semantics verified: game keeps the existing buffer when
-- FString.Max >= len+1 (0x77950a0), so the fork's pre-reserve (2048 wchars)
-- prevents ANY game-allocator call; fork dtor SystemFrees its own buffer.
return 0x7945dd0
