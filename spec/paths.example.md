# spec/paths.md — 장비별 경로 (이 파일을 paths.md 로 복사해 채운다)

`spec/paths.md` 는 .gitignore 대상이다. 개인 경로·API 키가 저장소에 올라가지 않는다.

```
KORDOC_CMD     = <예: C:\Users\<USER>\AppData\Roaming\npm\kordoc.cmd>
LLAMA_SERVER   = <예: C:\...\runtime\llama-server.exe>
CODER_GGUF     = <예: C:\...\models\qwen2.5-coder-7b-instruct-q4_k_m.gguf>
BGE_M3_GGUF    = <예: C:\...\models\bge-m3-q8_0.gguf>
PYTHON         = <예: C:\Users\<USER>\AppData\Local\Programs\Python\Python312\python.exe>

CTX_CODER      = 32768
NGL_CODER      = 99
ANYTHINGLLM_API_KEY = <AnythingLLM 설정 > API Keys 에서 발급>
ANYTHINGLLM_URL     = http://127.0.0.1:3001
UEI_WORKSPACE       = uei-manual
```

## VRAM 별 CTX_CODER 권장 (Qwen2.5-Coder-7B Q4_K_M ≈ 4.7GB)

| VRAM | CTX_CODER | 모델+KV 추정 |
|---|---|---|
| 8 GB | **32768** | 약 6.1 GB |
| 6 GB | 16384 | 약 5.4 GB |
| 12 GB+ | 65536 | 약 7.6 GB |

KV 계수 약 0.045 MiB/토큰 (Qwen3-4B 실측 0.115 를 구조비로 환산한 **추정치**).
데스크탑 실측 후 이 표를 갱신할 것. OOM 이면 한 단계 낮춘다.
