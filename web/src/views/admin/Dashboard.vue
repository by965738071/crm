<script setup>
import { onMounted, ref } from 'vue'
import { adminApi } from '../../api'

const loading = ref(false)
const stats = ref(null)

async function load() {
  loading.value = true
  try {
    stats.value = await adminApi.stats()
  } catch {} finally {
    loading.value = false
  }
}

const cards = [
  { key: 'users', label: '用户总数', icon: 'User', color: '#1e6ef5', bg: '#e8f0fe' },
  { key: 'users_today', label: '今日新增用户', icon: 'UserFilled', color: '#12b8a6', bg: '#e3faf5' },
  { key: 'users_7d', label: '近 7 日新增', icon: 'TrendCharts', color: '#67c23a', bg: '#eef9e6' },
  { key: 'courses', label: '课程数', icon: 'Notebook', color: '#f59e0b', bg: '#fdf5e4' },
  { key: 'questions', label: '题目数', icon: 'EditPen', color: '#8b5cf6', bg: '#f2edfe' },
  { key: 'orders_pending', label: '待支付订单', icon: 'List', color: '#f56c6c', bg: '#fdecec' },
]

onMounted(load)
</script>

<template>
  <div v-loading="loading">
    <div class="hd">
      <h3 class="title">数据看板</h3>
      <el-button text @click="load"><el-icon><Refresh /></el-icon>刷新</el-button>
    </div>
    <el-row :gutter="16">
      <el-col v-for="c in cards" :key="c.key" :xs="12" :sm="8" :md="8" :lg="4">
        <div class="card">
          <span class="ico" :style="{ background: c.bg, color: c.color }">
            <el-icon :size="22"><component :is="c.icon" /></el-icon>
          </span>
          <div class="num" :style="{ color: c.color }">{{ stats ? stats[c.key] : '-' }}</div>
          <div class="label">{{ c.label }}</div>
        </div>
      </el-col>
    </el-row>
  </div>
</template>

<style scoped>
.hd { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
.title { margin: 0; font-size: 17px; }
.card {
  position: relative;
  background: #fff; border: 1px solid #e8edf5; border-radius: 14px;
  padding: 18px 16px 16px; margin-bottom: 16px; overflow: hidden;
  transition: box-shadow 0.2s, transform 0.2s;
}
.card:hover { box-shadow: 0 10px 24px rgba(30, 110, 245, 0.10); transform: translateY(-2px); }
.ico {
  position: absolute; right: 14px; top: 14px;
  width: 40px; height: 40px; border-radius: 11px;
  display: flex; align-items: center; justify-content: center;
}
.num { font-size: 28px; font-weight: 700; line-height: 1.3; }
.label { font-size: 13px; color: var(--el-text-color-secondary); margin-top: 4px; }
</style>
