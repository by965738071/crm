<script setup>
import { onMounted, reactive, ref, watch } from 'vue'
import { resourceApi } from '../../api'
import { useProjectStore } from '../../stores/project'
import { fileSize, datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const project = useProjectStore()
const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ type: '', keyword: '', page: 1, size: 20 })

const typeOptions = [
  { value: '', label: '全部类型' },
  { value: 'video', label: '视频' },
  { value: 'audio', label: '音频' },
  { value: 'pdf', label: 'PDF' },
  { value: 'doc', label: '文档' },
  { value: 'image', label: '图片' },
  { value: 'markdown', label: 'Markdown' },
]
const typeLabel = Object.fromEntries(typeOptions.map((t) => [t.value, t.label]))

async function load() {
  loading.value = true
  try {
    const r = await resourceApi.list({
      ...project.scope(),
      type: query.type || undefined,
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

onMounted(load)
watch(
  () => project.currentId,
  () => search(),
)
</script>

<template>
  <div>
    <div class="page-title">
      <h3>资料中心</h3>
      <span class="sub">公开学习资料，可免费下载</span>
    </div>
    <div class="toolbar">
      <el-select v-model="query.type" style="width: 150px" @change="search">
        <el-option v-for="t in typeOptions" :key="t.value" :value="t.value" :label="t.label" />
      </el-select>
      <el-input
        v-model="query.keyword"
        placeholder="搜索资料名称"
        clearable
        style="width: 260px"
        @keyup.enter="search"
        @clear="search"
      />
      <el-button type="primary" @click="search">查询</el-button>
    </div>

    <div class="table-box">
      <el-table v-loading="loading" :data="items" stripe>
        <el-table-column label="名称" min-width="260">
          <template #default="{ row }">
            <el-icon class="file-ico"><Document /></el-icon>
            <span class="name">{{ row.name }}</span>
          </template>
        </el-table-column>
        <el-table-column label="类型" width="110">
          <template #default="{ row }">
            <el-tag size="small" type="info" effect="light">{{ typeLabel[row.rtype] || row.rtype }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="大小" width="110">
          <template #default="{ row }">{{ fileSize(row.size) }}</template>
        </el-table-column>
        <el-table-column label="上传时间" width="160">
          <template #default="{ row }">{{ datetime(row.created_at) }}</template>
        </el-table-column>
        <el-table-column label="操作" width="110" fixed="right">
          <template #default="{ row }">
            <el-button size="small" type="primary" plain :href="resourceApi.downloadUrl(row.id)" tag="a">
              <el-icon style="margin-right: 2px"><Download /></el-icon>下载
            </el-button>
          </template>
        </el-table-column>
      </el-table>
      <el-empty v-if="!loading && !items.length" description="暂无公开资料" />
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="load" />
  </div>
</template>

<style scoped>
.toolbar { display: flex; gap: 10px; margin-bottom: 18px; }
.table-box { background: #fff; border: 1px solid #e8edf5; border-radius: 14px; padding: 6px 14px; }
.file-ico { margin-right: 6px; color: var(--brand); font-size: 15px; vertical-align: -2px; }
.name { font-size: 14px; }
.el-tag { font-weight: 500; }

@media (max-width: 640px) {
  .toolbar { flex-direction: column; align-items: stretch; }
  .toolbar :deep(.el-select), .toolbar :deep(.el-input) { width: 100% !important; }
}
</style>
