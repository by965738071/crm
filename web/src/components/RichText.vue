<script setup>
// 富文本：把文本中的 markdown 图片语法 `![alt](/uploads/images/xxx.png)` 渲染成 <img>。
// 只放行本站图片上传路径（随机文件名），外部 URL / javascript: 等一律按原文输出，防止 XSS。
import { computed } from 'vue'

const props = defineProps({ text: { type: String, default: '' } })

const imgRe = /!\[([^\]]*)\]\((\/uploads\/images\/[A-Za-z0-9._\-/]+)\)/g

const parts = computed(() => {
  const out = []
  const s = props.text || ''
  let last = 0
  let m
  imgRe.lastIndex = 0
  while ((m = imgRe.exec(s))) {
    if (m.index > last) out.push({ t: 'text', v: s.slice(last, m.index) })
    out.push({ t: 'img', src: m[2], alt: m[1] })
    last = m.index + m[0].length
  }
  if (last < s.length) out.push({ t: 'text', v: s.slice(last) })
  return out
})
</script>

<template>
  <span class="rich-text">
    <template v-for="(p, i) in parts" :key="i">
      <img v-if="p.t === 'img'" :src="p.src" :alt="p.alt || '图'" class="rich-img" loading="lazy" />
      <template v-else>{{ p.v }}</template>
    </template>
  </span>
</template>

<style scoped>
.rich-img {
  display: inline-block;
  max-width: 100%;
  max-height: 320px;
  margin: 2px 6px;
  vertical-align: middle;
  border: 1px solid var(--el-border-color-lighter);
  border-radius: 4px;
}
</style>