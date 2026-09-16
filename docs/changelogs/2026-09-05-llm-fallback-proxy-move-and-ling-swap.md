# 2026-09-05 - LLM fallback proxy: moved to root as ###4, Tier 2 hy3 -> Ling pools

## What changed

1. `dev_tools/start_llm_fallback_proxy.ps1` -> `###4.start_llm_fallback_proxy.ps1` (repo root).
   - Verified before the move: no file referenced the old path. The ###1 watchers
     launcher (`###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1`,
     line ~1527) starts `dev_tools/llm_fallback_proxy.py` directly with its own
     auto-restart loop and never called this wrapper.
   - Path fixes for the new location: `.env` is now looked up next to the script
     (`$PSScriptRoot/.env`) and `$repoRoot` is `$PSScriptRoot` itself, so the log
     (`logs/llm_fallback_proxy.log`) and `dev_tools/llm_fallback_proxy.py` targets
     stay correct.

2. `dev_tools/llm_fallback_proxy.py` Tier 2 swap:
   - Removed: `{"model": "tencent/hy3:free", "label": "nous_hy3"}`.
   - Added: `nous-ling-3-0-flash-fin-pool` (label `nous_ling_fin`) and
     `nous-ling-3-0-flash-sante-pool` (label `nous_ling_sante`) - the registered
     LiteLLM pool names (`litellm_config.yaml` -> `inclusionai/ling-3.0-flash-*:free`
     via inference-api.nousresearch.com).
   - Rationale: logs/llm_fallback_proxy.log shows raw slashed Nous names
     (`tencent/hy3:free`, laguna/step/solar/longcat `:free`) get HTTP 400 from
     LiteLLM because they are not registered `model_name` values; only bare
     opencode names route. Pool names are the registered ones, so Tier 2 will
     actually serve. Live check: `GET /v1/models` on 127.0.0.1:4000 lists both
     Ling pools.

3. `tests/test_llm_fallback_proxy.py`:
   - `test_falls_through_tier2_hy3_when_tier1_exhausts` ->
     `test_falls_through_tier2_ling_when_tier1_exhausts` (asserts a ling label).
   - Tier-1 regression guard now also excludes the ling labels.

## Out of scope (flagged)

- `litellm_config.yaml` keeps the `nous-hy3` pool and `default_model: nous-hy3`;
  other consumers call `litellm/nous-hy3` directly.
- Tier 1/3 still use raw slashed Nous names that 400 against LiteLLM
  (`poolside/laguna-*:free`, `stepfun/step-3.7-flash:free`, `upstage/solar-pro4:free`,
  `meituan/longcat-2.0:free`). Converting them to their pool names
  (`nous-laguna-*-pool`, `nous-step-3-7-flash-pool`, `nous-solar-pro4-pool`,
  `nous-longcat-2-0-pool`) is a ready follow-up.

## Validation

- PowerShell Language.Parser ParseFile on `###4.start_llm_fallback_proxy.ps1`: PARSE OK.
- `python run_tests_isolated.py tests/test_llm_fallback_proxy.py`: PASSED (1/1 files).
- `GET http://127.0.0.1:4000/v1/models`: both Ling pools registered.
