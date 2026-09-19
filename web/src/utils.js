// 通用格式化：金额（分）、时间、文件大小、时长
export function money(cents) {
  if (!cents) return '免费'
  return `¥${(cents / 100).toFixed(2)}`
}

export function datetime(ts) {
  if (!ts) return '-'
  const d = new Date(ts * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

export function date(ts) {
  if (!ts) return '-'
  const d = new Date(ts * 1000)
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

export function fileSize(n) {
  if (!n) return '-'
  const units = ['B', 'KB', 'MB', 'GB']
  let i = 0
  let v = n
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i += 1
  }
  return `${v.toFixed(i ? 1 : 0)} ${units[i]}`
}

// 分类统计归并：把「直接挂在该分类下的计数」按分类树自底向上累加，
// 使父分类数字 = 自身 + 全部子孙分类，与列表「含子分类」查询语义一致。
export function rollupCategoryCounts(tree, m) {
  const out = {}
  const sum = (n) => {
    let t = m[n.id] || 0
    for (const c of n.children || []) t += sum(c)
    out[n.id] = t
    return t
  }
  for (const node of tree || []) sum(node)
  return out
}

export function duration(sec) {
  if (!sec) return '0:00'
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${m}:${String(s).padStart(2, '0')}`
}
