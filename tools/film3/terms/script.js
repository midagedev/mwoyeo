const T = [["제어가", "대조군이"], ["제어와", "대조군과"], ["제어 및", "대조군 및"], ["컨트롤", "대조군"], ["사인 테스트는", "부호 검정은"]]
function after(src, dst, ctx) {
  if (ctx.target !== "ko") return dst
  return T.reduce((s, [a, b]) => s.replaceAll(a, b), dst)
}
