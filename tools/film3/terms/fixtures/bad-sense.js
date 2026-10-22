const T = [["컨트롤", "대조군"], ["기억", "재현율"]]
function after(src, dst, ctx) {
  if (ctx.target !== "ko") return dst
  return T.reduce((s, [a, b]) => s.replaceAll(a, b), dst)
}
