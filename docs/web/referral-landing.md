# 친구 초대 랜딩 페이지 — 웹 작업 스펙 (iPad 1.4.1)

iPad 앱 1.4.1의 친구 초대 링크 `https://bandal.io/r/{코드}`가 도착하는 페이지입니다. 앱이 설치돼 있으면 이 주소는 유니버설 링크로 앱을 바로 열고, 없으면 이 페이지가 보입니다. 웹에서 할 일은 아래 두 가지입니다.

1. `/r/{코드}` 페이지
2. `apple-app-site-association`(AASA)에 `/r/*` 추가

## 1. `/r/{코드}` 페이지

### 주소

- 코드는 6자. 쓰는 글자는 `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (헷갈리는 `0 O 1 I L` 없음).
- 소문자로 들어와도 받습니다. 화면에는 대문자로 보여 주고, 주소는 그대로 둡니다(리다이렉트하면 유니버설 링크가 끊길 수 있음).
- 형식이 아닌 주소(`/r/`, `/r/abc`, `/r/ABC-234` 등)는 코드 없이 같은 화면(코드 칸과 복사 버튼만 빠짐)을 보여 줍니다. 404로 보내지 않습니다: 링크를 잘못 옮겨 적은 사람도 앱은 받을 수 있어야 합니다.
- 코드가 실제로 있는지는 확인하지 않아도 됩니다. 확인하려면 `GET https://<프로젝트>/functions/v1/referral/check?code=XXXXXX` (헤더 `apikey: <publishable key>`, 응답 `{"valid": true|false}`)를 쓸 수 있지만, 페이지는 정적으로 두는 쪽을 권합니다. 확인은 앱이 합니다.

### 화면 (모바일 우선, 한 화면)

| 요소 | 내용 |
|---|---|
| 코드 | 6자를 큰 고정폭 글씨로. 누르면 복사 |
| 복사 버튼 | "복사" → 누르면 "복사했어요"로 잠깐 바뀜 |
| App Store 버튼 | `https://apps.apple.com/app/id6824053530` (Apple 공식 배지) |
| 규칙 한 줄 | ko: "친구가 로그인하고 첫 과목을 만들면 둘 다 AI 100회를 받아요." / en: "When your friend signs in and creates their first course, you both get 100 AI questions." |
| 안내 한 줄 | ko: "반달을 설치한 뒤 첫 화면에서 이 코드를 넣어 주세요." / en: "Install Bandal, then enter this code on the first screen." |

- 언어: 사이트의 기존 방식(ko 기본, en)을 따릅니다.
- `<meta name="robots" content="noindex">`: 코드가 검색에 걸리지 않게 합니다.
- Smart App Banner: `<meta name="apple-itunes-app" content="app-id=6824053530, app-argument=https://bandal.io/r/{코드}">`. Safari에서 앱이 설치돼 있으면 위쪽에 "열기"가 뜹니다(주소창에 직접 친 경우 유니버설 링크가 동작하지 않기 때문에 필요).
- 공유 미리보기(Open Graph): 제목 "반달 초대", 설명은 위 규칙 한 줄. 코드는 미리보기 문구에 넣지 않아도 됩니다.
- 이 페이지는 코드 말고는 아무것도 받지 않습니다. 분석 도구를 붙인다면 주소의 코드가 수집되지 않게 해 주세요.
- iPad 전용 앱입니다. iPhone·데스크톱에서 열었을 때도 같은 화면을 보여 주되, App Store 버튼 아래에 "iPad용 앱이에요" 한 줄을 붙여 주세요.

### 앱이 하는 일 (참고)

- 앱이 이 주소로 열리면: 첫 실행 안내 중이면 "초대 코드" 단계에 코드가 채워지고, 이미 쓰던 기기면 설정 › 계정 › 친구 초대의 코드 칸에 채워집니다.
- 앱 안의 공유 문구: "반달에서 같이 공부하자. 초대 코드 {코드} 넣으면 둘 다 AI 100회 받아요. bandal.io/r/{코드}"

## 2. `apple-app-site-association`

`https://bandal.io/.well-known/apple-app-site-association` 에 아래 `applinks`가 들어가야 합니다. 이미 파일이 있으면 기존 항목(예: `webcredentials`)은 그대로 두고 `applinks`만 더합니다.

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["VUZ7Z98BW3.app.bandal.ipad"],
        "components": [
          { "/": "/r/*", "comment": "친구 초대 링크" }
        ]
      }
    ]
  }
}
```

- `Content-Type: application/json`, 확장자 없이, HTTPS 200으로 바로 응답해야 합니다(리다이렉트 금지, `www` → apex 리다이렉트도 금지).
- 앱의 Associated Domains는 `applinks:bandal.io` 하나입니다. `www.bandal.io`로도 링크를 뿌릴 계획이면 알려 주세요(앱 권한을 추가해야 함).
- Apple CDN이 이 파일을 최대 하루쯤 캐시합니다. **앱 1.4.1이 심사를 통과하기 전에** 먼저 배포해 주세요. 확인: `curl -sI https://bandal.io/.well-known/apple-app-site-association` 과 `https://app-site-association.cdn-apple.com/a/v1/bandal.io`.
- `/r/*` 말고 다른 경로는 넣지 마세요. 사이트의 다른 페이지가 앱으로 열리면 안 됩니다.

## 확인할 것

- [ ] iPad(앱 설치됨)에서 메모·메시지에 붙여 넣은 `https://bandal.io/r/ABC234`를 누르면 앱이 열리고 코드가 채워진다
- [ ] 같은 주소를 Safari 주소창에 치면 페이지가 뜨고 위에 "열기" 배너가 보인다
- [ ] 앱이 없는 기기에서 페이지가 뜨고 App Store 버튼이 앱 페이지로 간다
- [ ] 소문자 주소(`/r/abc234`)도 같은 결과
- [ ] `/r/`만 있는 주소는 코드 칸 없이 같은 화면
