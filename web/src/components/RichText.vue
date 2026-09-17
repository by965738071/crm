<script setup>
// 富文本：把文本中的 markdown 图片语法 `![alt](/uploads/images/xxx.png)` 渲染成悬浮查看的占位。
// 只放行本站图片上传路径（随机文件名），外部 URL / javascript: 等一律按原文输出，防止 XSS。
// 图片默认不占版面：显示「图N」小占位，鼠标 hover 弹出浮层大图（不挤压题干/选项布局）。
import { computed } from 'vue'

const props = defineProps({ text: { type: String, default: '' } })

const imgRe = /!\[([^\]]*)\]\((\/uploads\/images\/[A-Za-z0-9._\-/]+)\)/g

const parts = computed(() => {
  const out = []
  const s = props.text || ''
  let last = 0
  let m
  let imgNo = 0
  imgRe.lastIndex = 0
  while ((m = imgRe.exec(s))) {
    if (m.index > last) out.push({ t: 'text', v: s.slice(last, m.index) })
    imgNo += 1
    out.push({ t: 'img', src: m[2], alt: m[1], no: imgNo })
    last = m.index + m[0].length
  }
  if (last < s.length) out.push({ t: 'text', v: s.slice(last) })
  return out
})
</script>

<template>
  <span class="rich-text">
    <template v-for="(p, i) in parts" :key="i">
      <el-popover
        v-if="p.t === 'img'"
        :show-after="150"
        :hide-after="200"
        trigger="hover"
        placement="auto"
        :width="null"
        popper-class="rich-img-pop"
      >
        <el-image
          class="rich-img-pop-inner"
          :src="p.src"
          :alt="p.alt || '图'"
          :preview-src-list="[p.src]"
          :initial-index="0"
          fit="contain"
          preview-teleported
        />
        <template #reference>
          <span class="img-anchor" :title="p.alt || '查看图片'">
            <el-icon><Picture /></el-icon>图{{ p.no }}
          </span>
        </template>
      </el-popover>
      <template v-else>{{ p.v }}</template>
    </template>
  </span>
</template>

<style scoped>
.img-anchor {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  padding: 1px 8px;
  margin: 0 4px;
  font-size: 12px;
  color: var(--el-color-primary);
  background: var(--el-fill-color-light);
  border: 1px solid var(--el-border-color-lighter);
  border-radius: 4px;
  cursor: zoom-in;
  vertical-align: middle;
  white-space: nowrap;
}
.img-anchor:hover {
  color: var(--el-color-white);
  background: var(--el-color-primary);
}
</style>

<style>
/* 浮层被 teleport 到 body，需全局样式（非 scoped） */
.rich-img-pop {
  padding: 4px;
}
.rich-img-pop .el-image {
  display: block;
  width: min(480px, 80vw);
  height: 340px;
  border-radius: 4px;
  cursor: zoom-in;
}
</style>