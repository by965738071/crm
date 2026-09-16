<script setup>
import { reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuthStore } from '../../stores/auth'

const auth = useAuthStore()
const route = useRoute()
const router = useRouter()
const formRef = ref()
const loading = ref(false)
const form = reactive({ account: '', password: '' })
const rules = {
  account: [{ required: true, message: '请输入邮箱或用户名', trigger: 'blur' }],
  password: [{ required: true, message: '请输入密码', trigger: 'blur' }],
}

async function submit() {
  await formRef.value.validate()
  loading.value = true
  try {
    await auth.login({ account: form.account, password: form.password })
    const next = route.query.next
    router.push(typeof next === 'string' && next ? next : '/home')
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
          <h1>医学考试学习平台</h1>
          <p>专业课程 · 海量题库 · 全真模拟</p>
          <ul class="feats">
            <li><el-icon><CircleCheck /></el-icon>系统化备考课程体系</li>
            <li><el-icon><CircleCheck /></el-icon>智能刷题与错题回顾</li>
            <li><el-icon><CircleCheck /></el-icon>仿真模拟考试评分</li>
            <li><el-icon><CircleCheck /></el-icon>学习进度全程记录</li>
          </ul>
        </div>
      </div>

      <div class="form-side">
        <div class="form-inner">
          <div class="form-title">欢迎回来</div>
          <div class="form-sub">登录你的学习账号</div>
          <el-form ref="formRef" :model="form" :rules="rules" label-position="top" size="large" @submit.prevent="submit">
            <el-form-item prop="account">
              <el-input v-model="form.account" placeholder="邮箱 / 用户名" autofocus>
                <template #prefix><el-icon><User /></el-icon></template>
              </el-input>
            </el-form-item>
            <el-form-item prop="password">
              <el-input v-model="form.password" type="password" show-password placeholder="密码" @keyup.enter="submit">
                <template #prefix><el-icon><Lock /></el-icon></template>
              </el-input>
            </el-form-item>
            <el-button type="primary" size="large" class="btn" :loading="loading" @click="submit">登 录</el-button>
            <div class="tip">还没有账号？<router-link to="/register">立即注册</router-link></div>
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
  display: flex; width: 860px; max-width: 100%; min-height: 520px;
  border-radius: 18px; overflow: hidden;
  background: #fff; box-shadow: 0 20px 60px rgba(20, 40, 80, 0.18);
}
.brand-side {
  width: 42%;
  background: linear-gradient(150deg, #0d5bd6 0%, #1e6ef5 50%, #12b8a6 130%);
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
.form-inner { width: 100%; max-width: 320px; }
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