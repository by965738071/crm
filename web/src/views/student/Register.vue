<script setup>
import { reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { authApi } from '../../api'
import { useAuthStore } from '../../stores/auth'

const auth = useAuthStore()
const router = useRouter()
const formRef = ref()
const loading = ref(false)
const form = reactive({ email: '', username: '', password: '', confirm: '' })

const rules = {
  email: [
    { required: true, message: '请输入邮箱', trigger: 'blur' },
    { type: 'email', message: '邮箱格式不正确', trigger: 'blur' },
  ],
  username: [
    { required: true, message: '请输入用户名', trigger: 'blur' },
    { pattern: /^[a-zA-Z0-9_.-]{3,32}$/, message: '3-32 位字母、数字或 _-.', trigger: 'blur' },
  ],
  password: [
    { required: true, message: '请输入密码', trigger: 'blur' },
    { min: 8, max: 128, message: '密码长度需为 8-128 位', trigger: 'blur' },
  ],
  confirm: [
    { required: true, message: '请再次输入密码', trigger: 'blur' },
    {
      validator: (_r, v, cb) => (v === form.password ? cb() : cb(new Error('两次密码不一致'))),
      trigger: 'blur',
    },
  ],
}

async function submit() {
  await formRef.value.validate()
  loading.value = true
  try {
    await authApi.register({ email: form.email, username: form.username, password: form.password })
    ElMessage.success('注册成功，已自动登录')
    await auth.login({ account: form.email, password: form.password })
    router.push('/home')
  } catch {
    /* 拦截器已提示 */
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="wrap">
    <div class="panel">
      <div class="brand-side">
        <div class="brand-inner">
          <div class="logo">🩺</div>
          <h1>加入我们</h1>
          <p>开启高效医学备考之旅</p>
          <ul class="feats">
            <li><el-icon><CircleCheck /></el-icon>免费注册，即刻体验</li>
            <li><el-icon><CircleCheck /></el-icon>课程 / 题库 / 模拟考试随身学</li>
            <li><el-icon><CircleCheck /></el-icon>学习数据永久沉淀</li>
          </ul>
        </div>
      </div>

      <div class="form-side">
        <div class="form-inner">
          <div class="form-title">创建账号</div>
          <div class="form-sub">只需几步即可开始学习</div>
          <el-form ref="formRef" :model="form" :rules="rules" label-position="top" size="large" @submit.prevent="submit">
            <el-row :gutter="12">
              <el-col :span="12">
                <el-form-item label="邮箱" prop="email">
                  <el-input v-model="form.email" />
                </el-form-item>
              </el-col>
              <el-col :span="12">
                <el-form-item label="用户名" prop="username">
                  <el-input v-model="form.username" />
                </el-form-item>
              </el-col>
            </el-row>
            <el-form-item label="密码" prop="password">
              <el-input v-model="form.password" type="password" show-password placeholder="8-128 位" />
            </el-form-item>
            <el-form-item label="确认密码" prop="confirm">
              <el-input v-model="form.confirm" type="password" show-password @keyup.enter="submit" />
            </el-form-item>
            <el-button type="primary" size="large" class="btn" :loading="loading" @click="submit">注 册</el-button>
            <div class="tip">已有账号？<router-link to="/login">去登录</router-link></div>
          </el-form>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.wrap {
  min-height: 100vh;
  display: flex; align-items: center; justify-content: center;
  background:
    radial-gradient(800px 400px at 85% 0%, rgba(18, 184, 166, 0.10), transparent 60%),
    radial-gradient(700px 420px at 0% 100%, rgba(30, 110, 245, 0.12), transparent 60%),
    #f4f7fb;
  padding: 24px;
}
.panel {
  display: flex; width: 880px; max-width: 100%; min-height: 560px;
  border-radius: 18px; overflow: hidden;
  background: #fff; box-shadow: 0 20px 60px rgba(20, 40, 80, 0.18);
}
.brand-side {
  width: 40%;
  background: linear-gradient(150deg, #12b8a6 0%, #1e6ef5 60%, #0d5bd6 130%);
  color: #fff; padding: 44px 34px;
  display: flex; align-items: center;
}
.brand-inner .logo {
  width: 52px; height: 52px; border-radius: 14px;
  background: rgba(255, 255, 255, 0.18); backdrop-filter: blur(4px);
  display: flex; align-items: center; justify-content: center;
  font-size: 26px; margin-bottom: 20px;
}
.brand-inner h1 { font-size: 24px; margin: 0 0 8px; letter-spacing: 1px; }
.brand-inner p { margin: 0 0 26px; font-size: 14px; opacity: 0.9; }
.feats { list-style: none; padding: 0; margin: 0; }
.feats li { display: flex; align-items: center; gap: 8px; font-size: 14px; margin-bottom: 12px; opacity: 0.95; }
.form-side {
  flex: 1; display: flex; align-items: center; justify-content: center; padding: 40px;
}
.form-inner { width: 100%; max-width: 360px; }
.form-title { font-size: 26px; font-weight: 800; }
.form-sub { color: var(--el-text-color-secondary); font-size: 14px; margin: 6px 0 26px; }
.btn { width: 100%; margin-top: 6px; font-weight: 600; letter-spacing: 6px; }
.tip { margin-top: 16px; text-align: center; color: var(--el-text-color-secondary); font-size: 14px; }
.tip a { color: var(--brand); font-weight: 600; text-decoration: none; }

@media (max-width: 720px) {
  .brand-side { display: none; }
  .form-side { padding: 32px 24px; }
}
</style>