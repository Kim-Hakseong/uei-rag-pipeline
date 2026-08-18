# VSCode Continue 설정

이 저장소의 컨텍스트 서버(`:8099`)를 Continue 에 붙여 `@uei` 로 매뉴얼 근거를 불러온다.

## 1. 설정 파일 위치

| OS | 경로 |
|---|---|
| Windows | `%USERPROFILE%\.continue\config.yaml` |
| (구버전) | `%USERPROFILE%\.continue\config.json` |

Continue 최신은 **YAML** 을 쓴다. `config.json` 만 있는 구버전이면 아래 JSON 예시를 쓴다.

## 2. config.yaml

```yaml
name: uei-local
version: 0.0.1
schema: v1

models:
  - name: qwen2.5-coder-7b
    provider: openai
    model: qwen2.5-coder-7b        # llama-server 의 --alias 와 같은 값
    apiBase: http://127.0.0.1:8090/v1
    apiKey: local                   # llama-server 는 키를 검사하지 않는다
    roles: [chat, edit, apply]
    defaultCompletionOptions:
      contextLength: 32768          # spec/paths.md 의 CTX_CODER 와 같은 값
      maxTokens: 4096

context:
  - provider: file
  - provider: codebase              # .c 예제는 여기로 (RAG 에 넣지 않는다)
  - provider: diff
  - provider: terminal
  - provider: http
    params:
      url: http://127.0.0.1:8099/retrieve
      title: uei
      description: UEI 매뉴얼에서 근거 문단을 찾아온다
      displayTitle: UEI 매뉴얼
```

## 3. config.json (구버전)

```json
{
  "models": [
    {
      "title": "qwen2.5-coder-7b",
      "provider": "openai",
      "model": "qwen2.5-coder-7b",
      "apiBase": "http://127.0.0.1:8090/v1",
      "apiKey": "local",
      "contextLength": 32768
    }
  ],
  "contextProviders": [
    { "name": "file" },
    { "name": "codebase" },
    { "name": "diff" },
    { "name": "terminal" },
    {
      "name": "http",
      "params": {
        "url": "http://127.0.0.1:8099/retrieve",
        "title": "uei",
        "description": "UEI 매뉴얼에서 근거 문단을 찾아온다",
        "displayTitle": "UEI 매뉴얼"
      }
    }
  ]
}
```

## 4. 자동완성(FIM)을 쓰려면

`qwen2.5-coder`는 FIM(중간 채우기)을 지원한다. 탭 자동완성까지 원하면 모델을 하나 더 건다:

```yaml
  - name: qwen2.5-coder-7b-fim
    provider: openai
    model: qwen2.5-coder-7b
    apiBase: http://127.0.0.1:8090/v1
    apiKey: local
    roles: [autocomplete]
```

> 자동완성은 **매 타이핑마다** 서버를 호출한다. 8GB VRAM 에서 채팅과 함께 쓰면
> 응답이 느려질 수 있다. 느리면 이 블록을 빼고 채팅만 쓰는 편이 낫다. **미검증.**

## 5. 쓰는 법

```
@uei 인코더 분해능 설정 레지스터

위 근거대로 초기화 함수를 작성해줘. 예제는 @codebase 의 스타일을 따라줘.
```

- `@uei` — 매뉴얼 근거를 컨텍스트에 넣는다 (컨텍스트 서버 → 벡터 검색)
- `@codebase` — 프로젝트의 `.c` 예제를 Continue 가 자체 인덱싱해서 참조
- **매뉴얼 파일 자체를 `@file` 로 넣지 말 것.** 2MB 매뉴얼은 약 52만 토큰이라
  어떤 설정으로도 들어가지 않는다. 그래서 `@uei` 가 있는 것이다.

## 6. 질의 요령 (local-rag 실측 근거)

| 하지 말 것 | 대신 |
|---|---|
| `0x607B의 정의는?` | `Position Range Limit 오브젝트는 무엇에 쓰이는가?` |
| 인덱스 번호만 | **문서에 적힌 명칭을 함께** |
| "매뉴얼 전체 요약해줘" | 조회형으로 좁혀서 |

인덱스 번호만 쓰면 임베딩이 다른 문맥을 잡는다. 실측에서 번호 단독 질의는 실패했고
명칭을 넣은 질의는 정의 문장을 정확히 인용했다.

## 7. 문제 해결

| 증상 | 확인 |
|---|---|
| `@uei` 가 목록에 없음 | Continue 재시작. config 문법 오류면 Continue 출력 패널에 뜬다 |
| "연결 실패" 내용이 옴 | 컨텍스트 서버(`:8099`)와 AnythingLLM(`:3001`) 기동 확인 |
| "HTTP 403" 내용이 옴 | `spec/paths.md` 의 `ANYTHINGLLM_API_KEY` 확인 |
| "검색 결과 없음" | 워크스페이스에 매뉴얼이 **실제로 임베딩**됐는지 문서 관리 화면에서 확인 |
| 응답이 매우 느림 | `contextLength` 를 낮추거나 자동완성 모델을 뺀다 |

컨텍스트 서버는 실패해도 200 과 함께 **사람이 읽을 수 있는 안내**를 돌려준다.
Continue 는 응답 파싱에 실패하면 조용히 넘어가기 때문에, 일부러 그렇게 만들었다.
