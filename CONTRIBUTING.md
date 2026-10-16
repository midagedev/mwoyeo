# Contributing

[한국어](#한국어) below.

Thank you for looking at Mwoyeo. All help is welcome: a bug report, an idea, a screenshot of a bad translation, a
question, a fix.

## Issues

Open an issue for anything. There is no template, and nothing is too small. A rough note is fine.

These help when you have them:
- the app version (About) and the macOS version
- the source and target languages
- a screenshot of what the lens showed, and what you expected

## Pull requests

- Keep a PR to one change. Small PRs are easier to review.
- Run `cd Core && swift test`. Build steps are in the [README](README.en.md#development).
- If you change how text is read, erased or drawn, `Mwoyeo --render in.png out.png` runs the real pipeline on an
  image ([headless checks](README.en.md#headless-checks)). Before and after images in the PR help a lot.
- PRs are merged with a merge commit, so your commits stay in the history as you wrote them.

## AI-assisted contributions

Contributions made with AI tools are welcome, issues and PRs alike. You do not need to say that you used one. Please
check that the change works, as you would with any change.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

---

## 한국어

Mwoyeo에 관심 가져 주셔서 고마워요. 버그 제보, 아이디어, 어색한 번역 스크린샷, 질문, 수정 PR까지 무엇이든 도움이 돼요.

### 이슈

뭐든 자유롭게 이슈로 올려 주세요. 템플릿은 없고, 사소한 것도 괜찮아요. 대충 적어도 돼요.

있으면 도움이 되는 것:
- 앱 버전(정보 창)과 macOS 버전
- 원문 언어와 번역 언어
- 렌즈에 보인 화면 스크린샷과 기대했던 결과

### PR

- PR 하나에는 변경 하나만 담아 주세요. 작을수록 리뷰가 쉬워요.
- `cd Core && swift test`를 돌려 주세요. 빌드 방법은 [README](README.en.md#development)에 있어요.
- 글자를 읽거나 지우거나 그리는 부분을 바꿨다면 `Mwoyeo --render in.png out.png`로 실제 파이프라인을 이미지에 돌려 볼 수
  있어요([headless checks](README.en.md#headless-checks)). 전후 비교 이미지를 PR에 붙여 주면 큰 도움이 돼요.
- PR은 merge commit으로 합쳐요. 작성한 커밋이 그대로 히스토리에 남아요.

### AI를 이용한 기여

AI 도구로 만든 이슈와 PR도 환영해요. AI를 썼다고 굳이 밝히지 않아도 돼요. 다른 변경과 마찬가지로 동작하는지만 확인해 주세요.

### 라이선스

기여한 내용은 [MIT 라이선스](LICENSE)로 배포돼요.
