<script setup>
import { onMounted, reactive, ref } from 'vue'
import { announcementApi } from '../../api'
import { datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ keyword: '', page: 1, size: 10 })

const detail = ref(null)
const detailVisible = ref(false)

async function load() {
  loading.value = true
  try {
    const r = await announcementApi.list({
      keyword: query.keyword || undefined,
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

// 列表已带 content，详情直接展示，省一次请求
function open(row) {
  detail.value = row
  detailVisible.value = true
}

onMounted(load)
</script>

<template>
  <div>
    <div class="page-title">
      <h3>公告中心</h3>
      <span class="sub">平台动态与考试资讯</span>
    </div>
    <div class="toolbar">
      <el-input
        v-model="query.keyword"
        placeholder="搜索公告标题"
        clearable
        style="width: 260px"
        @keyup.enter="search"
        @clear="search"
      />
      <el-button type="primary" @click="search">查询</el-button>
    </div>

    <div class="ann-list" v-loading="loading">
      <div v-for="a in items" :key="a.id" class="ann" @click="open(a)">
        <div class="ann-ico"><el-icon :size="20"><Notification /></el-icon></div>
        <div class="ann-main">
          <div class="title">{{ a.title }}</div>
          <div class="sum ellipsis2">{{ a.content }}</div>
        </div>
        <div class="time">{{ datetime(a.published_at || a.created_at) }}</div>
      </div>
      <el-empty v-if="!loading && !items.length" description="暂无公告" />
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="load" />

    <el-dialog v-model="detailVisible" :title="detail?.title" width="640px" destroy-on-close
      @closed="detail = null">
      <div v-if="detail">
        <div class="dlg-time">{{ datetime(detail.published_at || detail.created_at) }}</div>
        <div class="dlg-body">{{ detail.content }}</div>
      </div>
    </el-dialog>
  </div>
</template>

<style scoped>
.toolbar { display: flex; gap: 10px; margin-bottom: 18px; }
.ann-list { background: #fff; border: 1px solid #e8edf5; border-radius: 14px; padding: 4px 22px; }
.ann {
  display: flex; align-items: center; gap: 16px;
  padding: 18px 4px; border-bottom: 1px dashed #e8edf5; cursor: pointer;
  transition: background 0.15s;
}
.ann:last-child { border-bottom: none; }
.ann:hover { background: #f8fbff; border-radius: 10px; }
.ann-ico {
  flex: none; width: 44px; height: 44px; border-radius: 12px;
  background: var(--brand-grad-soft); color: var(--brand);
  display: flex; align-items: center; justify-content: center;
}
.ann-main { flex: 1; min-width: 0; }
.title { font-size: 15px; font-weight: 600; }
.ann:hover .title { color: var(--brand); }
.sum { font-size: 13px; color: var(--el-text-color-secondary); margin-top: 4px; }
.time { flex: none; font-size: 12px; color: var(--el-text-color-placeholder); margin-left: 12px; }
.dlg-time { font-size: 12px; color: var(--el-text-color-secondary); margin-bottom: 10px; }
.dlg-body { white-space: pre-wrap; line-height: 1.8; font-size: 14px; }
.ellipsis2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

@media (max-width: 640px) {
  .ann { flex-wrap: wrap; }
  .time { margin-left: 60px; }
}
</style>
