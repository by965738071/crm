<script setup>
import { onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from './stores/auth'
import { setUnauthorizedHook } from './api/http'

const router = useRouter()
const auth = useAuthStore()

// 会话失效（401）统一处理：清登录态 → 跳登录页并带回跳地址
setUnauthorizedHook(() => {
  auth.clear()
  const cur = router.currentRoute.value
  if (cur.meta.auth) router.push({ path: '/login', query: { next: cur.fullPath } })
})

onMounted(() => {
  // 刷新页面恢复登录态（路由守卫也会兜底，这里让菜单尽早正确显示）
  if (auth.unknown) auth.loadMe().catch(() => {})
})
</script>

<template>
  <router-view />
</template>
