# mcpw-0uo - 70 orphaned gh_clean_* / gh_wt_* qdrant collections removed

Date: 2026-09-20 - Branch: mcpw-sweep-20260920-1305 - **Mutating** (qdrant collection DELETE)

Status: **DONE** - 70 empty orphan collections deleted, 0 skipped, 0 failures. Live grepai index verified intact and answering.

> **Correction to the causal story.** This bead originally implied the orphan collections fed the
> `Cleaned an optimization handle after timeout` warnings (bead mcpw-3jm). **That causal link is refuted**
> and this cleanup does **not** claim to fix those warnings. See section 6. This work is housekeeping:
> the orphans were genuinely orphaned and each carried a 32 MB WAL.

---

## 1. Environment (verified, not assumed)

| Item | Value |
|---|---|
| Container | `qdrant-grepai` |
| Image | `qdrant/qdrant:latest` (reports `version 1.19.1`) |
| State | `running`, `RestartCount=0`, started `2026-09-20T06:54:36.339937721Z` |
| REST / gRPC | `127.0.0.1:16333` / `16334` |
| `server-qdrant-1` | `qdrant/qdrant:v1.11.3`, started `2026-09-20T06:54:36.331258283Z` - **not touched** |

The container was **never restarted or recreated** during this work (`RestartCount=0`, identical
`StartedAt` before and after).

Per the known gotcha on this box, `netstat`/`Get-NetTCPConnection` show no LISTENING row for the
published port; every check below is a **live port probe**, not a table lookup. All `curl` calls use
`--noproxy '*'` because `HTTP_PROXY=127.0.0.1:6438` breaks localhost.

---

## 2. BEFORE - full collection inventory

```
TOTAL_COLLECTIONS=73
ORPHAN_PREFIX_MATCHES=70
NON_ORPHAN=3
TOTAL_POINTS=1578
TOTAL_SEGMENTS=584

=== NON-ORPHAN (real) COLLECTIONS ===
J__audio_MCP-Watchers                                        pts=1064     segs=8      status=green
J__audio_MCP-Watchers-wt-fixtests-1907                       pts=514      segs=8      status=green
J__audio_VAD                                                 pts=0        segs=8      status=green

=== ORPHAN-PREFIX COLLECTIONS ===
C__Users_yuni_AppData_Local_Temp_gh_clean_05fce7740e1141f6b1713d1ffc0d25bf pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_1bb6b315c4454749a63ed0283b398a50 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_25952c89d92a4db1a779a6c31766d24a pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2a1186767dc94874a1ac7293f80e7167 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2c780437da2a47a08d93cc6471d30e0e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2e4fa5974c1b486892b2882ed5b78d84 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_3f4927c228ba4523b0e536448303c823 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_4324c44914f349629e690a533c7d62ea pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_45f53389ceae4ec484c191b178999512 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_57d2626a8e85441da0ad8ab6a1105543 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_5815f3e814574e94b26df60d2edb9997 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_5c63339999114a418a43d7c267a3e835 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6995bce6b6d54ad194fb9d36975df731 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6a30e95e1e4a435db3d7d27a495fe3c7 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6bbf2625e1054616a75a251f999c9494 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6c3781b223bb495fa7d1966097230749 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_7a27c71adad74d1aa9fc1c54e1f416ec pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_875613041af04d99a5dfb6cd6c192577 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_905dc079bd784513ac96ab8ae28b3442 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_92937f031f5f4dfe8b095b074bf63bdd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_99b4d2a7fd2d4f4580741933e24fc66f pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_a99c4e901f574fb9968f0855345807a8 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b08f383fc4ab4225bb72148fa2d66410 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b227d9b2ca5a497daf10ce89b5f5bd6c pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b91f8df4bf1042a78f50a3a59f6f5454 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_bafce4e9809245779e44bcad96d89548 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_bd0f19f255b14fce9bf94e617780bed6 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_c6894797dd4b480983a010633d492505 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_cadcf74b5f7f4bd6a722568809182247 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_d6f64e1943be4ff8b12a4817e775f2a1 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_de9b764f4cc24560b24733d07238c303 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_e9158578df8c40508a553cb0dbc469a0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_eb551338c4a844898e3a09dd193b6553 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_ee1463fc7fd547d0b3e33ddbb93663fd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_fe64957bd7484bcd9c5fd75c1399b5f5 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0972da100fc14dcaba3dc8120fb6f486 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0dbafd97259b4714b60651552e9731b4 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0e164e065cef421b80e6d94ae43a4257 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_13283c430048430196db7266cbdd8988 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_187b662bcb384568a1ab7468b3a7c47d pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_3a4fa91722e340a999060741fa27b300 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_3cc915395dcb462888d51325023c06ca pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_537bc8bf3659464ab86185b1bda463d3 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_5b4ace7bf6c74ebca186ba07fc84fd98 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_63e9ca5baf76458f860463fc8d420f86 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_6ae2514614b1482b8f0dab11337a4d4e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_721784a851984218a1c42f0a1ab28cf3 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_7456de93912e4f0390f15223a22ddf61 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_77475c257d124c2f8297bbe25ec4a4f7 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_82aef88550784e61a3d97546696db3a2 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_8b0fd5a81c6f486ba3b9224b488c4b77 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_94c059c028a54e508456333a63ce6afd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_987b2e3610a741e8b6e45d6d1c5f0884 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a1b68d00c67d49299b55ad0c36288f26 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a6dbb05894d647fe80ae998c1de0b128 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a79d937cee15482d91c121f3d96503e0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a82f485c8b8c47fdbf0169c2cfc2556b pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_b4d0b137a1d041778073afeacb1e98a1 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_b9055bbfd8094cc08dd3de2838d41f97 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_c0c83c7a88174ba687ccd11f2ac557c0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_c62ae31e29db4c1e8fad9f0cd665d656 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_cce4c6d51cc14f4fbc15d3c37c58630e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_cee796697bf74a499fb2277e98b0bf28 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_d7f2f94ad927486997c14bf0931835ac pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_daccfd8c083243a6b2d5cd4e8e7b3224 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_e285014a7010439f963b9722de6a0369 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_ee8a34bd464f4fd781307760da793a8f pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_ef9e69d3aae84535b67e49b1082b0685 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_f4a000462b1b47daae6b4547574576e2 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_f84a203f8ad04f939491c7c0e51aeea5 pts=0        segs=8      status=green

ORPHAN_NONZERO_POINTS=0

SAFE_TO_DELETE_COUNT=70
```

### 2a. The 3 non-orphan (real) collections - all 1,578 points lived here

```
J__audio_MCP-Watchers                                        pts=1064     segs=8      status=green
J__audio_MCP-Watchers-wt-fixtests-1907                       pts=514      segs=8      status=green
J__audio_VAD                                                 pts=0        segs=8      status=green
```

### 2b. The 70 orphan-prefix collections - every one `points_count = 0`

```
C__Users_yuni_AppData_Local_Temp_gh_clean_05fce7740e1141f6b1713d1ffc0d25bf pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_1bb6b315c4454749a63ed0283b398a50 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_25952c89d92a4db1a779a6c31766d24a pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2a1186767dc94874a1ac7293f80e7167 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2c780437da2a47a08d93cc6471d30e0e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_2e4fa5974c1b486892b2882ed5b78d84 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_3f4927c228ba4523b0e536448303c823 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_4324c44914f349629e690a533c7d62ea pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_45f53389ceae4ec484c191b178999512 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_57d2626a8e85441da0ad8ab6a1105543 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_5815f3e814574e94b26df60d2edb9997 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_5c63339999114a418a43d7c267a3e835 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6995bce6b6d54ad194fb9d36975df731 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6a30e95e1e4a435db3d7d27a495fe3c7 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6bbf2625e1054616a75a251f999c9494 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_6c3781b223bb495fa7d1966097230749 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_7a27c71adad74d1aa9fc1c54e1f416ec pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_875613041af04d99a5dfb6cd6c192577 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_905dc079bd784513ac96ab8ae28b3442 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_92937f031f5f4dfe8b095b074bf63bdd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_99b4d2a7fd2d4f4580741933e24fc66f pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_a99c4e901f574fb9968f0855345807a8 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b08f383fc4ab4225bb72148fa2d66410 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b227d9b2ca5a497daf10ce89b5f5bd6c pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_b91f8df4bf1042a78f50a3a59f6f5454 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_bafce4e9809245779e44bcad96d89548 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_bd0f19f255b14fce9bf94e617780bed6 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_c6894797dd4b480983a010633d492505 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_cadcf74b5f7f4bd6a722568809182247 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_d6f64e1943be4ff8b12a4817e775f2a1 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_de9b764f4cc24560b24733d07238c303 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_e9158578df8c40508a553cb0dbc469a0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_eb551338c4a844898e3a09dd193b6553 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_ee1463fc7fd547d0b3e33ddbb93663fd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_clean_fe64957bd7484bcd9c5fd75c1399b5f5 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0972da100fc14dcaba3dc8120fb6f486 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0dbafd97259b4714b60651552e9731b4 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_0e164e065cef421b80e6d94ae43a4257 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_13283c430048430196db7266cbdd8988 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_187b662bcb384568a1ab7468b3a7c47d pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_3a4fa91722e340a999060741fa27b300 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_3cc915395dcb462888d51325023c06ca pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_537bc8bf3659464ab86185b1bda463d3 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_5b4ace7bf6c74ebca186ba07fc84fd98 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_63e9ca5baf76458f860463fc8d420f86 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_6ae2514614b1482b8f0dab11337a4d4e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_721784a851984218a1c42f0a1ab28cf3 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_7456de93912e4f0390f15223a22ddf61 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_77475c257d124c2f8297bbe25ec4a4f7 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_82aef88550784e61a3d97546696db3a2 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_8b0fd5a81c6f486ba3b9224b488c4b77 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_94c059c028a54e508456333a63ce6afd pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_987b2e3610a741e8b6e45d6d1c5f0884 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a1b68d00c67d49299b55ad0c36288f26 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a6dbb05894d647fe80ae998c1de0b128 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a79d937cee15482d91c121f3d96503e0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_a82f485c8b8c47fdbf0169c2cfc2556b pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_b4d0b137a1d041778073afeacb1e98a1 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_b9055bbfd8094cc08dd3de2838d41f97 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_c0c83c7a88174ba687ccd11f2ac557c0 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_c62ae31e29db4c1e8fad9f0cd665d656 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_cce4c6d51cc14f4fbc15d3c37c58630e pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_cee796697bf74a499fb2277e98b0bf28 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_d7f2f94ad927486997c14bf0931835ac pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_daccfd8c083243a6b2d5cd4e8e7b3224 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_e285014a7010439f963b9722de6a0369 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_ee8a34bd464f4fd781307760da793a8f pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_ef9e69d3aae84535b67e49b1082b0685 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_f4a000462b1b47daae6b4547574576e2 pts=0        segs=8      status=green
C__Users_yuni_AppData_Local_Temp_gh_wt_f84a203f8ad04f939491c7c0e51aeea5 pts=0        segs=8      status=green
```

---

## 3. Verification gate (run at delete time, not from a stale snapshot)

Each candidate was re-fetched individually (`GET /collections/{name}`) **immediately before** the
delete pass. A collection entered the delete set only if **all** held:

1. name starts with the literal prefix `C__Users_yuni_AppData_Local_Temp_gh_clean_` **or** `C__Users_yuni_AppData_Local_Temp_gh_wt_`; and
2. `points_count == 0`; and
3. name is not in a hard-coded `PROTECTED` set (`J__audio_MCP-Watchers`, `J__audio_MCP-Watchers-wt-fixtests-1907`, `J__audio_VAD`).

Result of the gate:

```
BEFORE_TOTAL=73
VERIFIED_EMPTY_ORPHANS=70
SKIPPED=0
ORPHAN_NONZERO_POINTS=0
```

**No prefixed collection had `points_count > 0`, so the STOP condition never fired.** Deletion used
explicit per-name `DELETE /collections/{urlencoded-name}` calls - never a wildcard - so no
non-matching collection could be swept in.

---

## 4. Deletion - 7 batches of 10, verified after every batch

```
BEFORE_TOTAL=73
VERIFIED_EMPTY_ORPHANS=70
SKIPPED=0

--- batch 1: 10 collections ---
   after batch: total=63 (expected 63)
--- batch 2: 10 collections ---
   after batch: total=53 (expected 53)
--- batch 3: 10 collections ---
   after batch: total=43 (expected 43)
--- batch 4: 10 collections ---
   after batch: total=33 (expected 33)
--- batch 5: 10 collections ---
   after batch: total=23 (expected 23)
--- batch 6: 10 collections ---
   after batch: total=13 (expected 13)
--- batch 7: 10 collections ---
   after batch: total=3 (expected 3)

DELETED=70
FAILED=0
AFTER_TOTAL=3
```

After each batch the script re-listed collections and asserted (a) the total dropped by exactly the
batch size, (b) none of the 3 protected collections had disappeared, and (c) no member of the batch
was still present. Any failure would have aborted the run; none occurred.

**Deleted: 70 - Skipped: 0 - Failed: 0.**

### 4a. Names deleted

`gh_clean_*` (35):

```
C__Users_yuni_AppData_Local_Temp_gh_clean_05fce7740e1141f6b1713d1ffc0d25bf
C__Users_yuni_AppData_Local_Temp_gh_clean_1bb6b315c4454749a63ed0283b398a50
C__Users_yuni_AppData_Local_Temp_gh_clean_25952c89d92a4db1a779a6c31766d24a
C__Users_yuni_AppData_Local_Temp_gh_clean_2a1186767dc94874a1ac7293f80e7167
C__Users_yuni_AppData_Local_Temp_gh_clean_2c780437da2a47a08d93cc6471d30e0e
C__Users_yuni_AppData_Local_Temp_gh_clean_2e4fa5974c1b486892b2882ed5b78d84
C__Users_yuni_AppData_Local_Temp_gh_clean_3f4927c228ba4523b0e536448303c823
C__Users_yuni_AppData_Local_Temp_gh_clean_4324c44914f349629e690a533c7d62ea
C__Users_yuni_AppData_Local_Temp_gh_clean_45f53389ceae4ec484c191b178999512
C__Users_yuni_AppData_Local_Temp_gh_clean_57d2626a8e85441da0ad8ab6a1105543
C__Users_yuni_AppData_Local_Temp_gh_clean_5815f3e814574e94b26df60d2edb9997
C__Users_yuni_AppData_Local_Temp_gh_clean_5c63339999114a418a43d7c267a3e835
C__Users_yuni_AppData_Local_Temp_gh_clean_6995bce6b6d54ad194fb9d36975df731
C__Users_yuni_AppData_Local_Temp_gh_clean_6a30e95e1e4a435db3d7d27a495fe3c7
C__Users_yuni_AppData_Local_Temp_gh_clean_6bbf2625e1054616a75a251f999c9494
C__Users_yuni_AppData_Local_Temp_gh_clean_6c3781b223bb495fa7d1966097230749
C__Users_yuni_AppData_Local_Temp_gh_clean_7a27c71adad74d1aa9fc1c54e1f416ec
C__Users_yuni_AppData_Local_Temp_gh_clean_875613041af04d99a5dfb6cd6c192577
C__Users_yuni_AppData_Local_Temp_gh_clean_905dc079bd784513ac96ab8ae28b3442
C__Users_yuni_AppData_Local_Temp_gh_clean_92937f031f5f4dfe8b095b074bf63bdd
C__Users_yuni_AppData_Local_Temp_gh_clean_99b4d2a7fd2d4f4580741933e24fc66f
C__Users_yuni_AppData_Local_Temp_gh_clean_a99c4e901f574fb9968f0855345807a8
C__Users_yuni_AppData_Local_Temp_gh_clean_b08f383fc4ab4225bb72148fa2d66410
C__Users_yuni_AppData_Local_Temp_gh_clean_b227d9b2ca5a497daf10ce89b5f5bd6c
C__Users_yuni_AppData_Local_Temp_gh_clean_b91f8df4bf1042a78f50a3a59f6f5454
C__Users_yuni_AppData_Local_Temp_gh_clean_bafce4e9809245779e44bcad96d89548
C__Users_yuni_AppData_Local_Temp_gh_clean_bd0f19f255b14fce9bf94e617780bed6
C__Users_yuni_AppData_Local_Temp_gh_clean_c6894797dd4b480983a010633d492505
C__Users_yuni_AppData_Local_Temp_gh_clean_cadcf74b5f7f4bd6a722568809182247
C__Users_yuni_AppData_Local_Temp_gh_clean_d6f64e1943be4ff8b12a4817e775f2a1
C__Users_yuni_AppData_Local_Temp_gh_clean_de9b764f4cc24560b24733d07238c303
C__Users_yuni_AppData_Local_Temp_gh_clean_e9158578df8c40508a553cb0dbc469a0
C__Users_yuni_AppData_Local_Temp_gh_clean_eb551338c4a844898e3a09dd193b6553
C__Users_yuni_AppData_Local_Temp_gh_clean_ee1463fc7fd547d0b3e33ddbb93663fd
C__Users_yuni_AppData_Local_Temp_gh_clean_fe64957bd7484bcd9c5fd75c1399b5f5
```

`gh_wt_*` (35):

```
C__Users_yuni_AppData_Local_Temp_gh_wt_0972da100fc14dcaba3dc8120fb6f486
C__Users_yuni_AppData_Local_Temp_gh_wt_0dbafd97259b4714b60651552e9731b4
C__Users_yuni_AppData_Local_Temp_gh_wt_0e164e065cef421b80e6d94ae43a4257
C__Users_yuni_AppData_Local_Temp_gh_wt_13283c430048430196db7266cbdd8988
C__Users_yuni_AppData_Local_Temp_gh_wt_187b662bcb384568a1ab7468b3a7c47d
C__Users_yuni_AppData_Local_Temp_gh_wt_3a4fa91722e340a999060741fa27b300
C__Users_yuni_AppData_Local_Temp_gh_wt_3cc915395dcb462888d51325023c06ca
C__Users_yuni_AppData_Local_Temp_gh_wt_537bc8bf3659464ab86185b1bda463d3
C__Users_yuni_AppData_Local_Temp_gh_wt_5b4ace7bf6c74ebca186ba07fc84fd98
C__Users_yuni_AppData_Local_Temp_gh_wt_63e9ca5baf76458f860463fc8d420f86
C__Users_yuni_AppData_Local_Temp_gh_wt_6ae2514614b1482b8f0dab11337a4d4e
C__Users_yuni_AppData_Local_Temp_gh_wt_721784a851984218a1c42f0a1ab28cf3
C__Users_yuni_AppData_Local_Temp_gh_wt_7456de93912e4f0390f15223a22ddf61
C__Users_yuni_AppData_Local_Temp_gh_wt_77475c257d124c2f8297bbe25ec4a4f7
C__Users_yuni_AppData_Local_Temp_gh_wt_82aef88550784e61a3d97546696db3a2
C__Users_yuni_AppData_Local_Temp_gh_wt_8b0fd5a81c6f486ba3b9224b488c4b77
C__Users_yuni_AppData_Local_Temp_gh_wt_94c059c028a54e508456333a63ce6afd
C__Users_yuni_AppData_Local_Temp_gh_wt_987b2e3610a741e8b6e45d6d1c5f0884
C__Users_yuni_AppData_Local_Temp_gh_wt_a1b68d00c67d49299b55ad0c36288f26
C__Users_yuni_AppData_Local_Temp_gh_wt_a6dbb05894d647fe80ae998c1de0b128
C__Users_yuni_AppData_Local_Temp_gh_wt_a79d937cee15482d91c121f3d96503e0
C__Users_yuni_AppData_Local_Temp_gh_wt_a82f485c8b8c47fdbf0169c2cfc2556b
C__Users_yuni_AppData_Local_Temp_gh_wt_b4d0b137a1d041778073afeacb1e98a1
C__Users_yuni_AppData_Local_Temp_gh_wt_b9055bbfd8094cc08dd3de2838d41f97
C__Users_yuni_AppData_Local_Temp_gh_wt_c0c83c7a88174ba687ccd11f2ac557c0
C__Users_yuni_AppData_Local_Temp_gh_wt_c62ae31e29db4c1e8fad9f0cd665d656
C__Users_yuni_AppData_Local_Temp_gh_wt_cce4c6d51cc14f4fbc15d3c37c58630e
C__Users_yuni_AppData_Local_Temp_gh_wt_cee796697bf74a499fb2277e98b0bf28
C__Users_yuni_AppData_Local_Temp_gh_wt_d7f2f94ad927486997c14bf0931835ac
C__Users_yuni_AppData_Local_Temp_gh_wt_daccfd8c083243a6b2d5cd4e8e7b3224
C__Users_yuni_AppData_Local_Temp_gh_wt_e285014a7010439f963b9722de6a0369
C__Users_yuni_AppData_Local_Temp_gh_wt_ee8a34bd464f4fd781307760da793a8f
C__Users_yuni_AppData_Local_Temp_gh_wt_ef9e69d3aae84535b67e49b1082b0685
C__Users_yuni_AppData_Local_Temp_gh_wt_f4a000462b1b47daae6b4547574576e2
C__Users_yuni_AppData_Local_Temp_gh_wt_f84a203f8ad04f939491c7c0e51aeea5
```

---

## 5. AFTER - verification

```
TOTAL_COLLECTIONS=3
ORPHAN_PREFIX_MATCHES=0
NON_ORPHAN=3
TOTAL_POINTS=1655
TOTAL_SEGMENTS=24

=== NON-ORPHAN (real) COLLECTIONS ===
J__audio_MCP-Watchers                                        pts=1141     segs=8      status=green
J__audio_MCP-Watchers-wt-fixtests-1907                       pts=514      segs=8      status=green
J__audio_VAD                                                 pts=0        segs=8      status=green

=== ORPHAN-PREFIX COLLECTIONS ===

ORPHAN_NONZERO_POINTS=0

SAFE_TO_DELETE_COUNT=0
```

```
J__audio_MCP-Watchers                                        pts=1141     segs=8      status=green
J__audio_MCP-Watchers-wt-fixtests-1907                       pts=514      segs=8      status=green
J__audio_VAD                                                 pts=0        segs=8      status=green
```

### 5a. How the live grepai index was confirmed to survive

Four independent checks, all after the deletes:

| # | Check | Command | Result |
|---|---|---|---|
| 1 | Collection still present + `green` | `GET /collections/J__audio_MCP-Watchers` | `status=green` |
| 2 | Exact point count | `POST .../points/count` with `{"exact":true}` | `{"count":1141}` |
| 3 | Read path (scroll) | `POST .../points/scroll` with `{"limit":3}` | `status: ok`, returns real point UUIDs |
| 4 | **Vector search path** | `POST .../points/query` with a 768-dim vector | `status: ok`, 2 hits returned |

Check 4 is the decisive one: it exercises the same HNSW/segment read path grepai uses, and it
returned hits. Check 2 also shows `points_count` **grew** from 1060 to 1141 across the window -
grepai was concurrently **writing** to the collection while the cleanup ran, which the container
served without error.

Structural fingerprint diff of the 3 real collections, before vs after:

| Collection | `config` | `segments_count` | `status` | `payload_schema` | points |
|---|---|---|---|---|---|
| `J__audio_MCP-Watchers` | identical | identical | identical | identical | 1060 -> 1141 |
| `J__audio_MCP-Watchers-wt-fixtests-1907` | identical | identical | identical | identical | 514 -> 514 |
| `J__audio_VAD` | identical | identical | identical | identical | 0 -> 0 |

Every config field (vector size 768 / Cosine, `wal_capacity_mb: 32`, optimizer + HNSW config),
`segments_count`, `status` and `payload_schema` is byte-identical. The only movement is
`J__audio_MCP-Watchers.points_count` rising 1060 to 1141, i.e. **live ingestion**, not damage.

Cross-check on the filesystem, independent of the REST API:

```
$ docker exec qdrant-grepai ls /qdrant/storage/collections
J__audio_MCP-Watchers
J__audio_MCP-Watchers-wt-fixtests-1907
J__audio_VAD

$ docker exec qdrant-grepai du -sh /qdrant/storage
139M    /qdrant/storage
```

Container log scan for errors since the cleanup:

```
$ docker logs --since 5m qdrant-grepai 2>&1 | grep -iE 'error|panic|fail|warn'
(no output)
```

### 5b. Arithmetic reconciliation

| Metric | Before | After | Delta |
|---|---|---|---|
| Collections | 73 | 3 | -70 |
| Orphan-prefix collections | 70 | 0 | -70 |
| Segments | 584 | 24 | -560 |
| Points | 1578 | 1655 | +77 (live grepai writes) |
| Storage | - | 139M | - |

`584 - (70 x 8) = 584 - 560 = 24` - exactly the segment count that remains, confirming the 70
deleted collections each held 8 segments and that no real segment was collateral.

---

## 6. The optimization-warning link is refuted (do not claim otherwise)

`docker logs qdrant-grepai` contains **exactly 7** occurrences of
`Cleaned an optimization handle after timeout, explicitly triggering optimizers`, all timestamped
**2026-09-18 / 2026-09-19** - i.e. entirely inside the container's *first* lifetime, before the
2026-09-20 06:54 restart:

| # | UTC |
|---|---|
| 1 | 2026-09-18T17:28:16.256323Z |
| 2 | 2026-09-18T21:04:54.245974Z |
| 3 | 2026-09-19T00:13:52.413981Z |
| 4 | 2026-09-19T05:14:17.356748Z |
| 5 | 2026-09-19T05:48:37.087030Z |
| 6 | 2026-09-19T06:22:03.653096Z |
| 7 | 2026-09-19T08:10:37.236091Z |

**Zero** have occurred since the restart. Meanwhile the collection count *grew* during the same
window (54 to 73 per this bead's own measurements, with creation resuming at 12:46, 17:24, 17:29,
17:37 and 17:42 on 2026-09-20) while emitting **zero** optimization warnings.

If empty-collection count were the trigger, that burst of new collections would have reproduced the
warning. It did not. **The collection-count hypothesis is therefore refuted**, and deleting these
orphans is not expected to change the warning frequency. Bead mcpw-3jm should be revisited with a
different hypothesis - the current data points at something tied to the *first* container lifetime
rather than to collection cardinality.

---

## 7. Safety ledger

| Constraint | Compliance |
|---|---|
| Only empty orphans matching the two prefixes deleted | Yes - 70/70 re-verified `points_count=0` at delete time |
| No wildcard delete while a non-matching collection could match | Yes - explicit per-name DELETE calls only |
| Container not restarted / recreated | Yes - `RestartCount=0`, identical `StartedAt` |
| `server-qdrant-1` untouched | Yes - no command addressed it; still `running` on v1.11.3 |
| No tracked file edited | Yes - this report is the only file written |
| No `git add` / `git commit` / `git checkout` | Yes - none run |

---

## 8. Exact commands run

```bash
# --- discovery ---
docker ps --format '{{.Names}} {{.Image}} {{.Status}}'
docker inspect qdrant-grepai --format '{{.Config.Image}} {{.State.Status}} {{.State.StartedAt}}'
curl --noproxy '*' -s -m 10 http://127.0.0.1:16333/collections
curl --noproxy '*' -s -m 10 http://127.0.0.1:16333/collections | tr ',' '\n' | grep -c '"name"'

# --- enumeration (full per-collection detail, before + after) ---
python C:/Temp/enum_qdrant.py | tee C:/Temp/before.txt
python C:/Temp/enum_qdrant.py | tee C:/Temp/after.txt

# --- real-collection fingerprint baseline ---
python C:/Temp/baseline_real.py > C:/Temp/real_before.json
python C:/Temp/baseline_real.py > C:/Temp/real_after.json

# --- the only mutating command (70x, explicit names, batched 10/10) ---
python C:/Temp/cleanup.py | tee C:/Temp/cleanup_log.txt

# --- post-cleanup proof the live index answers ---
curl --noproxy '*' -s -m 20 -X POST -H 'Content-Type: application/json' \
  -d '{"limit":3,"with_payload":false}' \
  'http://127.0.0.1:16333/collections/J__audio_MCP-Watchers/points/scroll'
curl --noproxy '*' -s -m 20 -X POST -H 'Content-Type: application/json' \
  -d '{"exact":true}' \
  'http://127.0.0.1:16333/collections/J__audio_MCP-Watchers/points/count'
curl --noproxy '*' -s -m 25 -X POST -H 'Content-Type: application/json' \
  -d '{"query":[1.0,0.0,...768 dims...],"limit":2,"with_payload":false}' \
  'http://127.0.0.1:16333/collections/J__audio_MCP-Watchers/points/query'

# --- health / no-restart / no-collateral checks ---
docker inspect qdrant-grepai --format 'image={{.Config.Image}} status={{.State.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}'
docker inspect server-qdrant-1 --format 'image={{.Config.Image}} status={{.State.Status}} started={{.State.StartedAt}}'
docker logs --since 5m qdrant-grepai 2>&1 | grep -iE 'error|panic|fail|warn'
docker logs -t qdrant-grepai 2>&1 | grep -iE 'cleaned an optimization handle after timeout'
docker exec qdrant-grepai ls /qdrant/storage/collections
docker exec qdrant-grepai du -sh /qdrant/storage
```

The mutating script `C:/Temp/cleanup.py` performs the prefix test, the `points_count == 0` test and
the protected-name test *in-process*, aborts with exit code 2 if any prefixed collection fails
verification, and aborts with exit code 3 if a protected collection ever goes missing.
