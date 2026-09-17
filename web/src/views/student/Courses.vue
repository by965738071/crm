<script setup>
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { categoryApi, courseApi } from '../../api'
import { money } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const router = useRouter()
const loading = ref(false)
const items = ref([])
const total = ref(0)
const cats = ref([])
const query = reactive({ category_id: undefined, keyword: '', page: 1, size: 12 })

const catProps = { label: 'name', value: 'id', children: 'children' }

async function load() {
  loading.value = true
  try {
    const r = await courseApi.list({
      category_id: query.category_id || 0,
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

onMounted(async () => {
  cats.value = await categoryApi.tree().catch(() => [])
  load()
})
</script>

<template>
  <div>
    <div class="page-title">
      <h3>课程中心</h3>
      <span class="sub">精选医学考试课程，助你系统备考</span>
    </div>
    <div class="toolbar">
      <div class="toolbar-box">
        <el-tree-select
          v-model="query.category_id"
          :data="cats"
          :props="catProps"
          node-key="id"
          check-strictly
          clearable
          placeholder="全部分类"
          style="width: 200px"
          @change="search"
        />
        <el-input
          v-model="query.keyword"
          placeholder="搜索课程标题/简介"
          clearable
          style="width: 260px"
          @keyup.enter="search"
          @clear="search"
        />
        <el-button type="primary" @click="search">查询</el-button>
      </div>
      <span class="count">共 {{ total }} 门课程</span>
    </div>

    <div v-loading="loading">
      <el-row :gutter="20">
        <el-col v-for="c in items" :key="c.id" :xs="12" :sm="8" :md="6" :lg="6" :xl="4">
          <div class="card" @click="router.push(`/courses/${c.id}`)">
            <div class="cover">
              <img v-if="c.cover" :src="c.cover" alt="" />
              <span v-else>{{ c.title.slice(0, 2) }}</span>
            </div>
            <div class="t ellipsis2">{{ c.title }}</div>
            <div class="sum ellipsis">{{ c.summary || '暂无简介' }}</div>
            <div class="meta">
              <span class="price">{{ c.is_free ? '免费' : money(c.price) }}</span>
              <span><el-icon><User /></el-icon> {{ c.enroll_count }} 人在学</span>
            </div>
          </div>
        </el-col>
      </el-row>
      <el-empty v-if="!loading && !items.length" description="没有找到课程" />
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="load" />
  </div>
</template>

<style scoped>
.toolbar { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 18px; }
.toolbar-box { display: flex; gap: 10px; }
.count { font-size: 13px; color: var(--el-text-color-secondary); }
.card {
  cursor: pointer; margin-bottom: 16px; overflow: hidden;
  background: #fff; border: 1px solid #e8edf5; border-radius: 14px;
  transition: box-shadow 0.2s, transform 0.2s;
}
.card:hover { box-shadow: 0 12px 28px rgba(30, 110, 245, 0.12); transform: translateY(-3px); }
.cover {
  height: 116px; overflow: hidden;
  background: linear-gradient(135deg, #1e6ef5, #12b8a6);
  color: #fff; font-size: 32px; font-weight: 700;
  display: flex; align-items: center; justify-content: center;
}
.cover img { width: 100%; height: 100%; object-fit: cover; }
.t { margin: 12px 14px 0; font-size: 15px; font-weight: 600; line-height: 1.4; min-height: 42px; }
.sum { font-size: 12px; color: var(--el-text-color-secondary); margin: 4px 14px 0; height: 18px; }
.meta { display: flex; justify-content: space-between; margin: 8px 14px 14px; font-size: 12px; color: var(--el-text-color-secondary); }
.meta .el-icon { vertical-align: -2px; }
.price { color: var(--el-color-danger); font-weight: 700; font-size: 14px; }
.ellipsis { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ellipsis2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

@media (max-width: 640px) {
  .toolbar, .toolbar-box { flex-direction: column; align-items: stretch; }
  .toolbar :deep(.el-select), .toolbar :deep(.el-input) { width: 100% !important; }
}
</style>
