<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { authApi } from '../../api'
import { useAuthStore } from '../../stores/auth'
import { datetime } from '../../utils'

const auth = useAuthStore()
const saving = ref(false)
const pwdSaving = ref(false)

const profileForm = reactive({ nickname: '', avatar: '' })
const pwdForm = reactive({ old_password: '', new_password: '', confirm: '' })

const role_map = {
  superadmin: { label: '超级管理员', type: 'danger' },
  admin: { label: '管理员', type: 'warning' },
  student: { label: '学员', type: 'primary' },
}

onMounted(() => {
  if (auth.user) {
    profileForm.nickname = auth.user.nickname || ''
    profileForm.avatar = auth.user.avatar || ''
  }
})

async function saveProfile() {
  saving.value = true
  try {
    const u = await authApi.updateProfile({ nickname: profileForm.nickname, avatar: profileForm.avatar })
    auth.setUser(u)
    ElMessage.success('资料已更新')
  } catch {
  } finally {
    saving.value = false
  }
}

async function savePassword() {
  if (pwdForm.new_password.length < 8) return ElMessage.warning('新密码长度至少 8 位')
  if (pwdForm.new_password !== pwdForm.confirm) return ElMessage.warning('两次输入的新密码不一致')
  pwdSaving.value = true
  try {
    await authApi.changePassword({ old_password: pwdForm.old_password, new_password: pwdForm.new_password })
    // 后端会轮换会话并通过 Set-Cookie 下发新 cookie，无需重新登录
    ElMessage.success('密码已修改')
    pwdForm.old_password = ''
    pwdForm.new_password = ''
    pwdForm.confirm = ''
  } catch {
  } finally {
    pwdSaving.value = false
  }
}
</script>

<template>
  <el-row :gutter="16">
    <el-col :span="10">
      <el-card shadow="never">
        <template #header>账号信息</template>
        <div class="id-head">
          <el-avatar :size="56" :src="auth.user?.avatar || undefined">
            {{ auth.displayName.slice(0, 1) }}
          </el-avatar>
          <div>
            <div class="name">{{ auth.displayName }}</div>
            <el-tag size="small" :type="role_map[auth.user?.role]?.type || 'info'">
              {{ role_map[auth.user?.role]?.label || auth.user?.role }}
            </el-tag>
          </div>
        </div>
        <el-descriptions :column="1" border class="desc">
          <el-descriptions-item label="邮箱">{{ auth.user?.email }}</el-descriptions-item>
          <el-descriptions-item label="用户名">{{ auth.user?.username }}</el-descriptions-item>
          <el-descriptions-item label="注册时间">{{ datetime(auth.user?.created_at) }}</el-descriptions-item>
        </el-descriptions>
      </el-card>
    </el-col>

    <el-col :span="14">
      <el-card shadow="never" class="mb">
        <template #header>修改资料</template>
        <el-form label-width="70px">
          <el-form-item label="昵称">
            <el-input v-model="profileForm.nickname" maxlength="64" show-word-limit />
          </el-form-item>
          <el-form-item label="头像">
            <el-input v-model="profileForm.avatar" placeholder="头像图片 URL（可留空）" maxlength="512" />
          </el-form-item>
          <el-form-item>
            <el-button type="primary" :loading="saving" @click="saveProfile">保存</el-button>
          </el-form-item>
        </el-form>
      </el-card>

      <el-card shadow="never">
        <template #header>修改密码</template>
        <el-form label-width="70px">
          <el-form-item label="原密码">
            <el-input v-model="pwdForm.old_password" type="password" show-password />
          </el-form-item>
          <el-form-item label="新密码">
            <el-input v-model="pwdForm.new_password" type="password" show-password placeholder="8-128 位" />
          </el-form-item>
          <el-form-item label="确认">
            <el-input v-model="pwdForm.confirm" type="password" show-password />
          </el-form-item>
          <el-form-item>
            <el-button type="primary" :loading="pwdSaving" @click="savePassword">修改密码</el-button>
          </el-form-item>
        </el-form>
      </el-card>
    </el-col>
  </el-row>
</template>

<style scoped>
.mb { margin-bottom: 16px; }
.id-head { display: flex; gap: 14px; align-items: center; margin-bottom: 16px; }
.name { font-size: 16px; font-weight: 600; margin-bottom: 4px; }
</style>
