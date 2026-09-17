<script setup>
import { nextTick, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '../../api'
import { datetime } from '../../utils'
import { useAuthStore } from '../../stores/auth'
import PaginationBar from '../../components/PaginationBar.vue'

const auth = useAuthStore()

const loading = ref(false)
const tableRef = ref(null)
const items = ref([])
const total = ref(0)
const query = reactive({ keyword: '', role: '', page: 1, size: 20 })

const roleMap = {
  student: { label: '学员', type: 'primary' },
  admin: { label: '管理员', type: 'warning' },
  superadmin: { label: '超级管理员', type: 'danger' },
}

const statusMap = {
  active: { label: '正常', type: 'success' },
  disabled: { label: '已禁用', type: 'info' },
}

function initial(row) {
  const name = row.nickname || row.username || ''
  return name ? name.charAt(0).toUpperCase() : 'U'
}

async function load() {
  loading.value = true
  try {
    const r = await adminApi.users({
      keyword: query.keyword || undefined,
      role: query.role || undefined,
      page: query.page,
      size: query.size,
    })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function triggerSlide() {
  const el = tableRef.value?.$el
  if (!el) return
  el.classList.remove('slide-enter')
  void el.offsetWidth
  el.classList.add('slide-enter')
}

async function onPage(p) {
  query.page = p
  await load()
  await nextTick()
  tableRef.value?.setScrollTop(0)
  triggerSlide()
}

function search() {
  query.page = 1
  load().then(() => nextTick().then(triggerSlide))
}

async function toggleStatus(row) {
  const disable = row.status === 'active'
  const ok = await ElMessageBox.confirm(
    disable
      ? `确定禁用用户「${row.username}」吗？禁用后该用户将无法登录。`
      : `确定启用用户「${row.username}」吗？`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.setUserStatus(row.id, disable ? 'disabled' : 'active')
    ElMessage.success('已更新')
    await load()
  } catch {}
}

async function changeRole(row) {
  const role = await ElMessageBox.prompt('输入新角色：student / admin / superadmin', '修改角色', {
    inputPattern: /^(student|admin|superadmin)$/,
    inputErrorMessage: '角色无效',
  }).then((v) => v.value).catch(() => '')
  if (!role) return
  try {
    await adminApi.setUserRole(row.id, role)
    ElMessage.success('已更新')
    await load()
  } catch {}
}

async function resetPassword(row) {
  const pwd = await ElMessageBox.prompt('输入新密码（8-128 位）', '重置密码', {
    inputType: 'password',
  }).then((v) => v.value).catch(() => '')
  if (!pwd) return
  if (pwd.length < 8) {
    ElMessage.warning('密码至少 8 位')
    return
  }
  try {
    await adminApi.resetUserPassword(row.id, pwd)
    ElMessage.success('已重置密码')
  } catch {}
}

onMounted(load)
</script>

<template>
  <div class="page-list">
    <div class="toolbar">
      <el-input
        v-model="query.keyword"
        class="w220"
        placeholder="用户名/昵称/邮箱"
        clearable
        @keyup.enter="search"
        @clear="search"
      >
        <template #prefix><el-icon><Search /></el-icon></template>
      </el-input>
      <el-select v-model="query.role" class="w150" placeholder="角色" @change="search">
        <el-option label="全部角色" value="" />
        <el-option label="学员" value="student" />
        <el-option label="管理员" value="admin" />
        <el-option label="超级管理员" value="superadmin" />
      </el-select>
      <el-button type="primary" @click="search">查询</el-button>
    </div>

    <div class="table-wrap">
    <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column prop="username" label="用户名" min-width="130" show-overflow-tooltip />
      <el-table-column label="昵称" min-width="180">
        <template #default="{ row }">
          <div class="user-cell">
            <el-avatar :size="30" :src="row.avatar || undefined">{{ initial(row) }}</el-avatar>
            <span>{{ row.nickname || '-' }}</span>
          </div>
        </template>
      </el-table-column>
      <el-table-column prop="email" label="邮箱" min-width="200" show-overflow-tooltip />
      <el-table-column label="角色" width="110">
        <template #default="{ row }">
          <el-tag size="small" :type="roleMap[row.role]?.type || 'info'">
            {{ roleMap[row.role]?.label || row.role }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag size="small" :type="statusMap[row.status]?.type || 'info'">
            {{ statusMap[row.status]?.label || row.status }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="注册时间" width="150">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="250" fixed="right">
        <template #default="{ row }">
          <el-button
            size="small"
            :type="row.status === 'active' ? 'warning' : 'success'"
            plain
            :disabled="auth.user?.id === row.id"
            @click="toggleStatus(row)"
          >
            {{ row.status === 'active' ? '禁用' : '启用' }}
          </el-button>
          <el-button
            v-if="auth.user?.role === 'superadmin' && row.id !== auth.user?.id"
            size="small"
            @click="changeRole(row)"
          >
            改角色
          </el-button>
          <el-button
            v-if="row.id !== auth.user?.id"
            size="small"
            type="danger"
            plain
            @click="resetPassword(row)"
          >
            重置密码
          </el-button>
        </template>
      </el-table-column>
      <template #empty>
        <el-empty description="暂无用户" />
      </template>
    </el-table>
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />
  </div>
</template>

<style scoped>
.page-list { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; flex: none; }
.w220 { width: 220px; }
.w150 { width: 150px; }
.user-cell { display: flex; align-items: center; gap: 8px; }
.table-wrap { flex: 1; min-height: 0; }
</style>
