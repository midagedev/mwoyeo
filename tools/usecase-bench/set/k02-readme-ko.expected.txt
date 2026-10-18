pixelmint: 가벼운 이미지 도구 모음
pixelmint은 파이썬으로 이미지를 그리고 저장하는 작은 라이브러리입니다. 외부 패키지가 필요하지 않습니다. (inline: pixelmint)
설치
아래 명령으로 설치합니다.
$ pip install pixelmint (keep)
사용법
Canvas 객체를 만들고 fill()로 색을 채운 뒤 저장하면 됩니다. (inline: Canvas ; fill())
from pixelmint import Canvas (keep)
c = Canvas(640, 480) # 캔버스를 만든다 (keep)
c.fill("#ffffff") # 흰색으로 채운다 (keep)
c.save("out.png") (keep)
기여하기
버그를 발견하면 이슈로 알려 주세요. 풀 리퀘스트를 열기 전에 pytest를 실행해 주세요. (inline: pytest)
