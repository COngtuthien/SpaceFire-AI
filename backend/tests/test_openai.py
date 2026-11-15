"""OpenAI adapter: request shape, parsing, error mapping and key selection (real SDK, mocked HTTP; no network, no key)."""
from __future__ import annotations

import json
import logging

import httpx
import pytest

openai = pytest.importorskip("openai")

from app.providers.llm import LLMError, OpenAIProvider, set_llm  # noqa: E402

from .conftest import requires_db  # noqa: E402

SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"}}, "required": ["answer"],
          "additionalProperties": False}
FAKE_KEY = "sk-test-key-never-sent-0123456789"
OTHER_KEY = "gemini-test-key-must-not-reach-openai"


def completion(content='{"answer": "ok"}', finish="stop", refusal=None, model="gpt-4.1-mini-2025-04-14"):
    return {"id": "chatcmpl-test", "object": "chat.completion", "created": 1, "model": model,
            "choices": [{"index": 0, "finish_reason": finish,
                         "message": {"role": "assistant", "content": content, "refusal": refusal}}],
            "usage": {"prompt_tokens": 812, "completion_tokens": 64, "total_tokens": 876}}


class Recorder:
    """httpx transport: answers each request with the next queued (status, json) and records what was sent."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        out = self.outcomes.pop(0)
        if isinstance(out, Exception):
            raise out
        status, body = out
        return httpx.Response(status, json=body, headers={"x-request-id": "req_test123"})


def provider(*outcomes, **kw):
    rec = Recorder(*outcomes)
    client = openai.OpenAI(api_key=FAKE_KEY, base_url=OpenAIProvider.DEFAULT_BASE_URL, max_retries=0,
                           http_client=httpx.Client(transport=httpx.MockTransport(rec)))
    return OpenAIProvider(FAKE_KEY, "gpt-4.1-mini", 45, client=client, **kw), rec


def test_request_shape_auth_and_parsing():
    p, rec = provider((200, completion()))
    assert p.generate_json("system rules", "question + evidence", SCHEMA) == {"answer": "ok"}
    req = rec.requests[0]
    assert str(req.url) == "https://api.openai.com/v1/chat/completions"
    assert req.headers["authorization"] == f"Bearer {FAKE_KEY}"
    body = json.loads(req.content)
    assert body["model"] == "gpt-4.1-mini" and body["store"] is False and body["temperature"] == 0.2
    assert body["messages"] == [{"role": "system", "content": "system rules"},
                                {"role": "user", "content": "question + evidence"}]
    rf = body["response_format"]
    assert rf["type"] == "json_schema" and rf["json_schema"]["strict"] is True and rf["json_schema"]["schema"] == SCHEMA
    assert body["max_completion_tokens"] == 2000  # the service asks for 16000; the demo cap wins
    assert p.last_call == {"model_version": "gpt-4.1-mini-2025-04-14", "latency_ms": p.last_call["latency_ms"],
                           "http_status": 200, "request_id": "req_test123", "input_tokens": 812, "output_tokens": 64}


def test_negative_temperature_omits_the_parameter():
    p, rec = provider((200, completion()), temperature=-1)
    p.generate_json("s", "u", SCHEMA)
    assert "temperature" not in json.loads(rec.requests[0].content)


def test_real_client_defaults():
    p = OpenAIProvider(FAKE_KEY, "gpt-4.1-mini", 45)
    assert str(p.client.base_url) == "https://api.openai.com/v1/" and p.client.max_retries == 0
    assert p.client.timeout.read == 45 and p.client.timeout.connect == 10
    assert FAKE_KEY not in repr(vars(p))


@pytest.mark.parametrize("status,body,kind,text", [
    (401, {"error": {"message": f"Incorrect API key provided: {FAKE_KEY[:8]}****", "code": "invalid_api_key"}},
     "auth", "HTTP 401"),
    (403, {"error": {"message": "Project does not have access to model", "code": "model_not_found"}}, "auth", "403"),
    (404, {"error": {"message": "The model does not exist", "code": "model_not_found"}}, "bad_request", "not available"),
    (429, {"error": {"message": "You exceeded your current quota", "code": "insufficient_quota"}}, "rate_limit",
     "billing"),
    (429, {"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}, "rate_limit", "rate limit"),
    (400, {"error": {"message": "Invalid schema for response_format", "code": None}}, "bad_request", "Invalid schema"),
    (500, {"error": {"message": "server error"}}, "unavailable", "HTTP 500"),
])
def test_errors_are_mapped_without_retry_or_key(status, body, kind, text, caplog):
    caplog.set_level(logging.DEBUG)
    p, rec = provider((status, body))
    with pytest.raises(LLMError) as e:
        p.generate_json("s", "u", SCHEMA)
    assert e.value.kind == kind and text in str(e.value)
    assert len(rec.requests) == 1  # never retried: no doubled latency, no repeated paid request
    assert FAKE_KEY not in str(e.value) and FAKE_KEY not in caplog.text
    if body["error"].get("code") == "insufficient_quota":
        assert e.value.retry_after == 600.0  # pauses synthesis instead of re-sending doomed requests


def test_timeout_and_connection_errors():
    req = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
    p, _ = provider(httpx.ReadTimeout("slow", request=req))
    with pytest.raises(LLMError) as e:
        p.generate_json("s", "u", SCHEMA)
    assert e.value.kind == "timeout" and "45 s" in str(e.value)
    p, _ = provider(httpx.ConnectError("down", request=req))
    with pytest.raises(LLMError) as e:
        p.generate_json("s", "u", SCHEMA)
    assert e.value.kind == "unavailable"


@pytest.mark.parametrize("payload,kind", [
    (completion(content=None, refusal="I can't help with that."), "refusal"),
    (completion(finish="content_filter"), "refusal"),
    (completion(content='{"answer": "cut', finish="length"), "bad_output"),
    (completion(content="not json"), "bad_output"),
    (completion(content="[1, 2]"), "bad_output"),
    (completion(content="  "), "bad_output"),
])
def test_bad_outputs(payload, kind):
    p, _ = provider((200, payload))
    with pytest.raises(LLMError) as e:
        p.generate_json("s", "u", SCHEMA)
    assert e.value.kind == kind


# --- configuration: which key reaches which provider ------------------------------------------------------------------

def _settings(monkeypatch, **env):
    from app.core.config import get_settings
    for k in ("LLM_PROVIDER", "LLM_MODEL", "LLM_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY"):
        monkeypatch.setenv(k, env.get(k, ""))
    get_settings.cache_clear()
    return get_settings()


@pytest.fixture
def restore_settings(monkeypatch):
    from app.core.config import get_settings
    from app.providers import llm
    yield
    monkeypatch.undo()  # restore the blanked test environment before the settings are re-read
    llm._override_set = True
    llm._cached = None
    get_settings.cache_clear()


def test_openai_key_selection_never_borrows_another_providers_key(monkeypatch, restore_settings):
    s = _settings(monkeypatch, LLM_PROVIDER="openai", OPENAI_API_KEY=FAKE_KEY, GEMINI_API_KEY=OTHER_KEY)
    assert s.llm_key == FAKE_KEY and s.llm_key_source == "OPENAI_API_KEY"
    s = _settings(monkeypatch, LLM_PROVIDER="openai", GEMINI_API_KEY=OTHER_KEY)
    assert s.llm_key == "" and not s.llm_configured          # a Gemini key is never used for OpenAI
    s = _settings(monkeypatch, LLM_PROVIDER="gemini", OPENAI_API_KEY=FAKE_KEY, GEMINI_API_KEY=OTHER_KEY)
    assert s.llm_key == OTHER_KEY and s.llm_key_source == "GEMINI_API_KEY"
    s = _settings(monkeypatch, LLM_PROVIDER="openai", LLM_API_KEY=FAKE_KEY)
    assert s.llm_key == FAKE_KEY and s.llm_key_source == "LLM_API_KEY"  # generic key still works
    assert FAKE_KEY not in repr(s) and OTHER_KEY not in repr(s)


def test_get_llm_selects_openai_without_any_fallback(monkeypatch, restore_settings):
    from app.providers import llm
    _settings(monkeypatch, LLM_PROVIDER="openai", LLM_MODEL="gpt-4.1-mini", OPENAI_API_KEY=FAKE_KEY,
              GEMINI_API_KEY=OTHER_KEY)
    monkeypatch.setattr(llm, "_override_set", False)
    prov = llm.get_llm()
    assert isinstance(prov, OpenAIProvider) and prov.model == "gpt-4.1-mini" and llm.get_llm() is prov
    st = llm.llm_status()
    assert st == {"configured": True, "provider": "openai", "model": "gpt-4.1-mini", "mode": "synthesis",
                  "reason": None, "key_source": "OPENAI_API_KEY"}
    assert FAKE_KEY not in json.dumps(st) and OTHER_KEY not in json.dumps(st)


# --- end to end through the Copilot API with the real adapter (mocked OpenAI HTTP) --------------------------------

@requires_db
def test_copilot_answer_through_openai_adapter_is_verified(client):
    answer = {"answer": "FLEX recorded droplet burns on the ISS [cite-1].", "status": "answered",
              "claims": [{"text": "FLEX burns are recorded in the evidence.", "kind": "COMPUTED",
                          "citation_ids": ["cite-1"], "conditions": ""},
                         {"text": "Invented source.", "kind": "DOC", "citation_ids": ["cite-999"], "conditions": ""}],
              "limitations": [], "suggested_followups": ["Which fuels were tested?"]}
    p, rec = provider((200, completion(json.dumps(answer))), (200, completion(json.dumps({**answer, "claims":
                                                                                           answer["claims"][:1]}))))
    set_llm(p)
    j = client.post("/api/v1/assistant/ask", json={"question": "How many FLEX tests are in the database?",
                                                   "source_scope": "internal"}).json()
    sent = json.loads(rec.requests[0].content)["messages"][1]["content"]
    assert "<evidence_pack" in sent and FAKE_KEY not in sent       # NASA evidence pack is what the model sees
    ids = {c["citation_id"] for c in j["citations"]}
    assert j["status"] in ("answered", "partial") and j["claims"]
    assert all(set(c["citation_ids"]) <= ids for c in j["claims"])  # the invented cite-999 never reaches the UI
    assert j["llm"]["provider"] == "openai" and j["llm"]["calls"] >= 1
    assert j["llm"]["model_version"] == "gpt-4.1-mini-2025-04-14"
