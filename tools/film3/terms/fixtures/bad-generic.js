const T = [["제어", "대조군"], ["컨트롤", "대조군"], ["사인 테스트", "부호 검정"], ["소음", "잡음"]]
function after(src, dst, ctx) {
  if (ctx.target !== "ko") return dst
  return T.reduce((s, [a, b]) => s.replaceAll(a, b), dst)
}
