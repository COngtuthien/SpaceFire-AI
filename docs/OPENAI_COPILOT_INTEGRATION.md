# OpenAI Research Copilot Integration

The Research Copilot can now use the official OpenAI API (`https://api.openai.com/v1`, official `openai` Python SDK)
as its language-model provider. NASA retrieval, the knowledge graph, question classification, citation and number
verification, unsupported-question refusal, the answer cache and the evidence-only fallback are unchanged. The model
only phrases answers from the evidence pack, and code verifies every statement before it is shown.

## Configuration

Set these in the repository root `.env`, which is gitignored and read by `backend/app/core/config.py`:

```ini
LLM_PROVIDER=openai
LLM_MODEL=gpt-4.1-mini
OPENAI_API_KEY=<your key>
LLM_TIMEOUT_S=45
# optional: LLM_MAX_OUTPUT_TOKENS=2000, LLM_TEMPERATURE=0.2 (negative = omit)
```

Key selection:
- Each provider reads its own key variable: `OPENAI_API_KEY` for `openai`, `GEMINI_API_KEY` for `gemini`.
- When that variable is empty, the provider falls back to `LLM_API_KEY`.
- A key is never sent to a provider other than the one named in `LLM_PROVIDER`.
- Gemini stays available by switching `LLM_PROVIDER=gemini` and `LLM_MODEL=gemini-3.8-flash`.
- There is no automatic fallback between providers.

The health endpoint reports the variable that supplied the key (`llm.key_source`), never its value.

## Adapter behaviour (`OpenAIProvider` in `backend/app/providers/llm.py`)

| Aspect | Behaviour |
|---|---|
| Request | Chat Completions with Structured Outputs (`response_format` json_schema, `strict: true`) using the same answer schema as the other providers; `store: false` |
| Limits | `max_completion_tokens` = min(service request, `LLM_MAX_OUTPUT_TOKENS`, default 2000); timeout `LLM_TIMEOUT_S` (connect 10 s); `max_retries=0` |
| Base URL | Explicit `https://api.openai.com/v1`, so a stray `OPENAI_BASE_URL` in the shell cannot redirect the key |
| Parsing | `refusal` or `content_filter` → refusal; `length` → truncated; empty, non-JSON or non-object output → bad_output |
| Errors | 401 → auth (key); 403 → auth (project or model access); 404 → model not available; 429 `insufficient_quota` → billing message and a 10-minute synthesis pause; other 429 → rate limit; 400 → bad request; timeout or 5xx → unavailable. Every failure falls back to evidence only. |
| Metadata | Actual model version, latency, HTTP status, request id, input and output tokens (shown in the UI as "Written by …") |

## Verification (2026-11-15)

**Mocked tests.** `backend/tests/test_openai.py` has 20 tests. They use the real SDK with mocked HTTP and cover:
- request shape and Bearer auth
- error mapping without retries
- bad outputs
- key isolation between providers
- an end-to-end Copilot answer in which an invented citation is removed

The full backend suite passed: 285 tests.

**Live calls.** Three paid requests were made in total.

| # | Request | Result |
|---|---|---|
| 1 | Connectivity (tiny JSON prompt, 16-token cap) | HTTP 200, `gpt-4.1-mini-2025-04-14`, 2.25 s, 52 input / 5 output tokens, JSON parsed |
| 2 | Copilot: "What experimental conditions produced the reported cool flames in ACME CFI-G?" | HTTP 200, 3.08 s, 3,476 / 337 tokens. Status **partial**. One verified statement: cool-flame radii 5.1–7.6 mm and durations about 3.4–14 s, citing CFI-G Final Report Table 3, PDF page 46. One statement was **correctly rejected**: it gave the oxygen mole fraction as "0.39–0.40", but the cited table lists 0.385–0.399 at 2.03 bar, so "0.40" is not in the evidence. |
| 3 | Copilot: "How does microgravity affect droplet combustion in the FLEX experiments?" | HTTP 200, 5.96 s, 2,129 / 430 tokens. Status **answered**. Three verified statements, citing the FLEX Research Requirements Document (PDF pages 75 and 16) and NASA's "Cool Flames in Space" article (page 3). |

Two caveats on these results:
- **No correction call during testing.** To stay within three calls, the test allowed only one model call per question. In normal operation the service sends one correction request when a statement fails verification and the first call was fast.
- **Attribution is not verified.** In the FLEX answer, the "~2 mm/s quiescent" sentence comes from the Requirements Document's description of earlier droplet experiments (Nayagam et al., 1998). The model presented it as FLEX itself. The verifier checks citations and numbers, not attribution.

**Restart.** The backend was started, stopped and started again with the normal configuration. Both times
`/api/v1/health` reported `provider: openai`, `model: gpt-4.1-mini`, `mode: synthesis`, `key_source: OPENAI_API_KEY`.

**Frontend.** A production build passed, and eslint and `tsc --noEmit` were clean. The UI checks used a backend
whose OpenAI URL pointed at a closed local port, so no paid call was possible:
- Both answers render on `/copilot` with "Written by gpt-4.1-mini-2025-04-14" (from the saved answers), numbered NASA
  source references and the sources list.
- The Copilot error and fallback e2e spec passed (11 tests).
- No key was found in the build output (852 files) or in 70 browser network responses.

## Files

- `backend/app/core/config.py`: provider-specific keys, output cap, temperature
- `backend/app/providers/llm.py`: `OpenAIProvider` and provider selection
- `backend/requirements.txt`: `openai==3.51.0`
- `backend/tests/test_openai.py`: new tests
- `backend/tests/conftest.py` and `backend/app/eval/phase14_eval.py`: blank all provider keys, so tests and offline evaluation never call a paid API
- `.env.example`, `scripts/setup.*`, `README.md`, and three provider-neutral UI strings
