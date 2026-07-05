# PROVIDERS.md — Provider Setup Guide

Quick-start instructions for each supported provider. Copy-paste ready.

---

## Anthropic (original)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./eval.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

Optional overrides:
```bash
export MODEL=claude-haiku-4-5       # default
export BASE_URL=https://api.anthropic.com  # default
```

---

## OpenAI

```bash
export OPENAI_API_KEY=sk-...
export MODEL=gpt-4o-mini            # or gpt-4o, gpt-4-turbo, etc.
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

---

## OpenClaw (HTTP API)

Find your port with `openclaw status`, then:

```bash
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:PORT
export MODEL=claude-sonnet-4-6      # or whichever model OpenClaw is configured to use
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

> **Note:** Check the running model with `openclaw status`. Replace `PORT` with the
> actual port shown (commonly `19200` for gateway, check your config).

---

## Hermes / NousResearch models

### Via Ollama

```bash
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:11434/v1
export MODEL=hermes-3-llama-3.1-8b
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

### Via LM Studio

```bash
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:1234/v1
export MODEL=NousResearch/Hermes-3-Llama-3.1-8B-GGUF
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

---

## Azure OpenAI

Azure deployments use a non-standard URL format. Set `BASE_URL` to the deployment root
(without `/chat/completions` — the script appends `/v1/chat/completions` automatically
via the OpenAI-compat path).

```bash
export OPENAI_API_KEY=your-azure-key
export BASE_URL=https://your-resource.openai.azure.com/openai/deployments/your-deployment
export MODEL=gpt-4o
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

> **Azure note:** Azure endpoints may require `api-version` query param. If the default
> doesn't work, set `BASE_URL` to a compatible base and check Azure docs for the
> `/chat/completions` path format for your deployment.

---

## Local (Ollama, LM Studio, vLLM)

### Ollama

```bash
# Pull model first: ollama pull llama3.1
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:11434/v1
export MODEL=llama3.1
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

### LM Studio

```bash
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:1234/v1
export MODEL=your-loaded-model-name
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

### vLLM

```bash
export OPENAI_API_KEY=none
export BASE_URL=http://localhost:8000/v1
export MODEL=meta-llama/Llama-3.1-8B-Instruct
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus.tsv
```

---

## Corpus Options

| Corpus | Language | Notes |
|--------|----------|-------|
| `corpus/intent_eval_corpus.tsv` | English | Original corpus |
| `corpus/intent_eval_corpus_vi.tsv` | Vietnamese | Polite/indirect phrasing, social engineering |

Use the Vietnamese corpus to test multilingual evasion:

```bash
./eval_openai.sh reference_classifier_prompt.txt corpus/intent_eval_corpus_vi.tsv
```

---

## Behavioral Eval (Real Agent Compliance Testing)

The `eval_behavioral.sh` script sends corpus messages directly to the **running OpenClaw agent**
and uses a judge LLM to determine if the agent REFUSED or COMPLIED.

> **Prerequisite:** OpenClaw must be running and reachable via `openclaw agent --message`.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./eval_behavioral.sh judge_prompt.txt corpus/intent_eval_corpus.tsv
```

Optional overrides:
```bash
export MODEL=claude-haiku-4-5       # judge model (lightweight recommended)
export BASE_URL=https://api.anthropic.com  # judge API base
export SESSION_PREFIX=my-eval       # session-id prefix for openclaw calls
```

Smoke test (10 messages only):
```bash
head -30 corpus/intent_eval_corpus.tsv | grep -v '^#' | grep -v '^$' | head -10 > /tmp/smoke.tsv
export ANTHROPIC_API_KEY=sk-ant-...
./eval_behavioral.sh judge_prompt.txt /tmp/smoke.tsv
```

Difference from classifier eval:

| | `eval.sh` | `eval_behavioral.sh` |
|---|---|---|
| Tests | Guard LLM intent classifier | Real agent response behavior |
| What it catches | Classification gaps | Agent compliance failures |
| Speed | Fast | Slow (full agent turn per msg) |

See `AGENT.md` Section 10 for full comparison and output interpretation.

---

## Quick Reference

| Provider | Script | Key env vars |
|----------|--------|--------------|
| Anthropic | `eval.sh` | `ANTHROPIC_API_KEY` |
| OpenAI | `eval_openai.sh` | `OPENAI_API_KEY` |
| OpenClaw | `eval_openai.sh` | `OPENAI_API_KEY=none` + `BASE_URL` + `MODEL` |
| Hermes / NousResearch | `eval_openai.sh` | `OPENAI_API_KEY=none` + `BASE_URL` + `MODEL` |
| Azure OpenAI | `eval_openai.sh` | `OPENAI_API_KEY` + `BASE_URL` (deployment URL) + `MODEL` |
| Ollama / LM Studio / vLLM | `eval_openai.sh` | `OPENAI_API_KEY=none` + `BASE_URL` + `MODEL` |
