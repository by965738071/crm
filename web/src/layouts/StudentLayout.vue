<script setup>
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessageBox } from 'element-plus'
import { useAuthStore } from '../stores/auth'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const activeMenu = computed(() => {
  const p = route.path
  if (p.startsWith('/courses')) return '/courses'
  if (p.startsWith('/lessons')) return '/me/courses'
  if (p.startsWith('/practice')) return '/practice'
  if (p.startsWith('/wrong-book')) return '/wrong-book'
  if (p.startsWith('/exam')) return '/exams'
  if (p.startsWith('/me/')) return p
  return p
})

async function onLogout() {
  try {
    await ElMessageBox.confirm('确定退出登录？', '提示', { type: 'warning' })
  } catch {
    return // 用户取消
  }
  await auth.logout().catch(() => {})
  router.push('/login')
}

function onCommand(cmd) {
  if (cmd === 'logout') onLogout()
  else router.push(cmd)
}
</script>

<template>
  <el-container class="page">
    <el-header class="hd" height="64px">
      <div class="hd-inner">
        <div class="brand" @click="router.push('/home')">
          <span class="logo">🩺</span>
          <span class="brand-text">医学考试学习平台</span>
        </div>
        <el-menu :default-active="activeMenu" mode="horizontal" router class="nav" :ellipsis="false">
          <el-menu-item index="/home">首页</el-menu-item>
          <el-menu-item index="/courses">课程</el-menu-item>
          <el-menu-item index="/resources">资料</el-menu-item>
          <template v-if="auth.isLoggedIn">
            <el-menu-item index="/practice">练习</el-menu-item>
            <el-menu-item index="/wrong-book">错题/收藏</el-menu-item>
            <el-menu-item index="/exams">模拟考试</el-menu-item>
            <el-menu-item index="/announcements">公告</el-menu-item>
          </template>
          <el-menu-item v-else index="/announcements">公告</el-menu-item>
        </el-menu>
        <div class="usr">
          <template v-if="auth.isLoggedIn">
            <el-dropdown @command="onCommand">
              <span class="usr-name">
                <el-avatar :size="28" :src="auth.user?.avatar || undefined" class="usr-avatar">
                  {{ auth.displayName.slice(0, 1) }}
                </el-avatar>
                {{ auth.displayName }}<el-icon class="el-icon--right"><ArrowDown /></el-icon>
              </span>
              <template #dropdown>
                <el-dropdown-menu>
                  <el-dropdown-item v-if="auth.isAdmin" command="/admin">
                    <el-icon><Setting /></el-icon>管理后台
                  </el-dropdown-item>
                  <el-dropdown-item command="/me/courses">
                    <el-icon><Reading /></el-icon>我的课程
                  </el-dropdown-item>
                  <el-dropdown-item command="/me/notes">
                    <el-icon><Notebook /></el-icon>我的笔记
                  </el-dropdown-item>
                  <el-dropdown-item command="/me/favorites">
                    <el-icon><Star /></el-icon>我的收藏
                  </el-dropdown-item>
                  <el-dropdown-item command="/me/orders">
                    <el-icon><List /></el-icon>我的订单
                  </el-dropdown-item>
                  <el-dropdown-item command="/me/profile">
                    <el-icon><User /></el-icon>个人中心
                  </el-dropdown-item>
                  <el-dropdown-item command="logout" divided>
                    <el-icon><SwitchButton /></el-icon>退出登录
                  </el-dropdown-item>
                </el-dropdown-menu>
              </template>
            </el-dropdown>
          </template>
          <template v-else>
            <el-button size="default" class="btn-login" @click="router.push('/login')">登录</el-button>
            <el-button size="default" type="primary" class="btn-reg" @click="router.push('/register')">免费注册</el-button>
          </template>
        </div>
      </div>
    </el-header>
    <el-main class="bd">
      <router-view />
    </el-main>
    <el-footer class="ft">
      <div class="ft-inner">
        <div class="ft-brand">🩺 医学考试学习平台</div>
        <div class="ft-text">专业医学考试在线学习 · 课程 / 题库 / 模拟考试</div>
        <div class="ft-copy">© {{ new Date().getFullYear() }} Medical Exam Platform</div>
      </div>
    </el-footer>
  </el-container>
</template>

<style scoped>
.page { min-height: 100vh; }

.hd {
  padding: 0;
  background: rgba(255, 255, 255, 0.80);
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  border-bottom: 1px solid rgba(230, 237, 247, 0.9);
  position: sticky;
  top: 0;
  z-index: 100;
  box-shadow: 0 4px 20px rgba(30, 110, 245, 0.05);
}
.hd-inner {
  max-width: 1800px; margin: 0 auto; padding: 0 28px;
  display: flex; align-items: center; height: 100%; gap: 26px;
}
.brand {
  display: flex; align-items: center; gap: 10px;
  font-weight: 800; font-size: 17px; white-space: nowrap; cursor: pointer; letter-spacing: 0.5px;
}
.logo {
  width: 36px; height: 36px; border-radius: 10px;
  background: var(--brand-grad); color: #fff;
  display: flex; align-items: center; justify-content: center; font-size: 18px;
  box-shadow: 0 6px 14px rgba(30, 110, 245, 0.35);
}
.brand-text {
  background: var(--brand-grad);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}
.nav {
  flex: 1; border-bottom: none !important;
  --el-menu-horizontal-height: 40px;
}
.nav :deep(.el-menu-item) {
  height: 40px !important;
  line-height: 40px !important;
  border-radius: 6px;
  margin: 0 2px;
  font-size: 15px;
  padding: 0 16px;
  color: var(--el-text-color-regular) !important;
  transition: color 0.2s, background 0.15s;
}
.nav :deep(.el-menu-item:hover) {
  color: var(--brand) !important;
  background: var(--el-color-primary-light-9) !important;
}
.nav :deep(.el-menu-item.is-active) {
  color: var(--brand) !important;
  font-weight: 600;
  background: transparent !important;
  border-bottom: none !important;
  box-shadow: none !important;
  position: relative;
}
.nav :deep(.el-menu-item.is-active)::after {
  content: "";
  position: absolute;
  left: 16px; right: 16px; bottom: 4px;
  height: 2.5px;
  border-radius: 2px;
  background: var(--brand-grad);
}
.usr { white-space: nowrap; }
.usr-name {
  cursor: pointer; color: var(--el-text-color-primary); display: flex; align-items: center; gap: 7px;
  font-size: 14px; padding: 6px 10px; border-radius: 20px;
  transition: background 0.2s;
}
.usr-name:hover { background: var(--el-color-primary-light-9); }
.usr-avatar { background: var(--brand-grad); color: #fff; font-size: 13px; box-shadow: 0 2px 8px rgba(30, 110, 245, 0.3); }
.btn-login { border-color: #c9d8f5; color: var(--brand); border-radius: 20px; padding: 8px 20px; }
.btn-reg { border-radius: 20px; padding: 8px 20px; }
.btn-reg:hover { transform: none; }

.bd {
  width: 100%;
  max-width: 1800px;
  margin: 0 auto;
  padding: 10px 28px 48px;
  min-height: calc(100vh - 64px - 150px);
}

.ft {
  background: #fff;
  border-top: 1px solid var(--border-soft);
  position: relative;
  height: auto;
  padding: 30px 28px 34px;
}
.ft::before {
  content: "";
  position: absolute; top: 0; left: 0; right: 0; height: 2px;
  background: var(--brand-grad);
  opacity: 0.7;
}
.ft-inner { max-width: 1800px; margin: 0 auto; text-align: center; }
.ft-brand {
  display: inline-flex; align-items: center; gap: 6px;
  font-weight: 800; font-size: 15px;
  background: var(--brand-grad); -webkit-background-clip: text; background-clip: text; color: transparent;
}
.ft-text { color: var(--el-text-color-secondary); font-size: 13px; margin-top: 8px; }
.ft-copy { color: var(--el-text-color-placeholder); font-size: 12px; margin-top: 4px; }

@media (max-width: 900px) {
  .hd-inner { gap: 12px; padding: 0 16px; }
  .brand-text { display: none; }
  .bd { padding: 10px 14px 40px; }
}
</style>
