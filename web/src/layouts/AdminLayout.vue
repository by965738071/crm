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
  if (p.startsWith('/admin/courses')) return '/admin/courses' // 课时_editing 也归课程菜单高亮
  return p
})

const menus = [
  { path: '/admin/dashboard', title: '数据看板', icon: 'DataLine' },
  { path: '/admin/users', title: '用户管理', icon: 'User' },
  { path: '/admin/categories', title: '分类管理', icon: 'Folder' },
  { path: '/admin/courses', title: '课程管理', icon: 'Notebook' },
  { path: '/admin/resources', title: '资料管理', icon: 'Files' },
  { path: '/admin/questions', title: '题库管理', icon: 'EditPen' },
  { path: '/admin/exams', title: '试卷管理', icon: 'Histogram' },
  { path: '/admin/orders', title: '订单管理', icon: 'List' },
  { path: '/admin/announcements', title: '公告管理', icon: 'Bell' },
  { path: '/admin/logs', title: '日志管理', icon: 'Tickets' },
]

const hdTitle = computed(
  () => menus.find((m) => route.path.startsWith(m.path))?.title || '管理后台',
)

async function onLogout() {
  try {
    await ElMessageBox.confirm('确定退出登录？', '提示', { type: 'warning' })
  } catch {
    return
  }
  await auth.logout().catch(() => {})
  router.push('/login')
}
</script>

<template>
  <el-container class="page">
    <el-aside width="220px" class="side">
      <div class="brand">
        <span class="logo">🩺</span>
        <span>管理后台</span>
      </div>
      <el-menu :default-active="activeMenu" router class="menu" background-color="transparent"
        text-color="#aab4c8" active-text-color="#ffffff">
        <el-menu-item v-for="m in menus" :key="m.path" :index="m.path">
          <el-icon><component :is="m.icon" /></el-icon>
          <span>{{ m.title }}</span>
        </el-menu-item>
      </el-menu>
      <div class="side-foot">Medical Exam Admin</div>
    </el-aside>
    <el-container class="wrap">
      <el-header class="hd" height="56px">
        <div class="hd-title">{{ hdTitle }}</div>
        <div class="hd-right">
          <el-button text @click="router.push('/home')">
            <el-icon><HomeFilled /></el-icon>返回学员端
          </el-button>
          <el-dropdown @command="(c) => c === 'logout' && onLogout()">
            <span class="usr-name">
              <el-avatar :size="26" :src="auth.user?.avatar || undefined" class="usr-avatar">
                {{ auth.displayName.slice(0, 1) }}
              </el-avatar>
              {{ auth.displayName }}
              <el-tag size="small" :type="auth.user?.role === 'superadmin' ? 'danger' : 'warning'" class="role-tag">
                {{ auth.user?.role === 'superadmin' ? '超级管理员' : '管理员' }}
              </el-tag>
              <el-icon class="el-icon--right"><ArrowDown /></el-icon>
            </span>
            <template #dropdown>
              <el-dropdown-menu>
                <el-dropdown-item command="logout">退出登录</el-dropdown-item>
              </el-dropdown-menu>
            </template>
          </el-dropdown>
        </div>
      </el-header>
      <el-main class="bd">
        <router-view />
      </el-main>
    </el-container>
  </el-container>
</template>

<style scoped>
.page { height: 100vh; overflow: hidden; }
.wrap { height: 100%; min-height: 0; }
.side {
  background: linear-gradient(180deg, #0c1d36 0%, #0b2a4a 100%);
  display: flex; flex-direction: column; height: 100%;
}
.brand {
  display: flex; align-items: center; justify-content: center; gap: 8px;
  color: #fff; font-weight: 700; font-size: 16px; letter-spacing: 1px;
  height: 56px; flex: none;
}
.logo {
  width: 28px; height: 28px; border-radius: 8px;
  background: var(--brand-grad); color: #fff;
  display: flex; align-items: center; justify-content: center; font-size: 15px;
}
.menu { border-right: none; flex: 1; overflow-y: auto; }
.menu :deep(.el-menu-item) { border-radius: 8px; margin: 2px 10px; }
.menu :deep(.el-menu-item.is-active) {
  background: linear-gradient(90deg, rgba(30, 110, 245, 0.95), rgba(18, 184, 166, 0.75));
  color: #fff !important;
}
.side-foot { color: #40536e; font-size: 11px; text-align: center; padding: 14px 0; letter-spacing: 1px; }
.hd {
  display: flex; align-items: center; justify-content: flex-end; gap: 12px;
  background: #fff; border-bottom: 1px solid #e6ecf6;
  box-shadow: 0 2px 8px rgba(20, 40, 80, 0.04);
  padding: 0 20px;
}
.hd-title {
  margin-right: auto; font-size: 16px; font-weight: 700;
}
.hd-right { display: flex; align-items: center; gap: 14px; }
.usr-name { cursor: pointer; display: flex; align-items: center; gap: 6px; color: var(--el-text-color-primary); font-size: 14px; }
.usr-avatar { background: var(--brand-grad); color: #fff; font-size: 12px; }
.role-tag { margin-left: 2px; }
.bd {
  background: #f4f7fb;
  padding: 8px 20px 24px;
  max-width: 1700px;
  width: 100%;
  margin: 0 auto;
  overflow-y: auto;
  min-height: 0;
}
</style>
