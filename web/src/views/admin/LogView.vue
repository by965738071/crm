<script setup>
import { onMounted, reactive, ref } from 'vue'
import { adminApi } from '../../api'
import { datetime } from '../../utils'

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ user_id: '', page: 1, size: 50 })

async function load() {
  loading.value = true
  try {
    const r = await adminApi.auditLogs({
      user_id: query.user_id || undefined,
      page: query.page,
      size: query.size,
    })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function search() {
  query.page = 1
  load()
}

onMounted(load)
</script>

<template>
  <div>
    <div class="toolbar">
      <el-input
        v-model="query.user_id"
        class="w180"
        placeholder="按用户 ID 筛选"
        clearable
        @keyup.enter="search"
        @clear="search"
      />
      <el-button type="primary" @click="search">查询</el-button>
      <span class="tip">审计日志由 audit_middleware 实时写入；运行日志文件见 data/logs/app.log（框架 Logger 自动轮转）</span>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column prop="user_id" label="用户 ID" width="90" />
      <el-table-column prop="action" label="动作" width="100">
        <template #default="{ row }">
          <el-tag size="small" type="info">{{ row.action }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="request_summary" label="请求摘要" min-width="260" show-overflow-tooltip />
      <el-table-column prop="ip" label="来源 IP" width="150" show-overflow-tooltip />
      <el-table-column label="时间" width="170">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
    </el-table>
    <el-empty v-if="!loading && !items.length" description="暂无审计日志" />

    <el-pagination
      v-if="total > query.size"
      class="pager"
      layout="prev, pager, next, total"
      :total="total"
      :page-size="query.size"
      :current-page="query.page"
      @current-change="(p) => { query.page = p; load() }"
    />
  </div>
</template>

<style scoped>
.toolbar { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
.w180 { width: 180px; }
.tip { color: var(--el-text-color-secondary); font-size: 12px; }
.pager { margin-top: 12px; justify-content: center; }
</style>