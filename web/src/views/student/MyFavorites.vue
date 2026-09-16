<script setup>
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { favoriteApi } from '../../api'
import { money, datetime } from '../../utils'

const router = useRouter()
const loading = ref(false)
const tab = ref('course') // course | resource
const items = ref([])
const total = ref(0)
const query = reactive({ page: 1, size: 10 })

async function load() {
  loading.value = true
  try {
    const r = await favoriteApi.list({ target_type: tab.value, page: query.page, size: query.size })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function switchTab() {
  query.page = 1
  load()
}

async function remove(row) {
  await favoriteApi.remove(row.target_type, row.target_id)
  ElMessage.success('已取消收藏')
  load()
}

function openTarget(row) {
  if (row.target_type === 'course') router.push(`/courses/${row.target_id}`)
  else router.push('/resources')
}

onMounted(load)
</script>

<template>
  <div>
    <el-tabs v-model="tab" @tab-change="switchTab">
      <el-tab-pane label="收藏的课程" name="course" />
      <el-tab-pane label="收藏的资料" name="resource" />
    </el-tabs>

    <div v-loading="loading">
      <el-row :gutter="12">
        <el-col v-for="row in items" :key="row.id" :span="8">
          <el-card class="item" shadow="hover">
            <div class="flex" @click="openTarget(row)">
              <div class="cover">
                <img v-if="row.cover" :src="row.cover" alt="" />
                <span v-else>{{ (row.title || '?').slice(0, 2) }}</span>
              </div>
              <div class="main">
                <div class="t ellipsis2">{{ row.title }}</div>
                <div class="meta">
                  <el-tag v-if="row.target_type === 'resource'" size="small" type="info">{{ row.rtype }}</el-tag>
                  <span v-else class="price">{{ row.price ? money(row.price) : '免费' }}</span>
                  <span class="time">{{ datetime(row.created_at) }} 收藏</span>
                </div>
              </div>
            </div>
            <div class="ops">
              <el-button size="small" type="danger" plain @click="remove(row)">取消收藏</el-button>
            </div>
          </el-card>
        </el-col>
      </el-row>
      <el-empty v-if="!loading && !items.length" description="暂无收藏" />
    </div>

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
.item { margin-bottom: 12px; }
.flex { display: flex; gap: 10px; cursor: pointer; }
.cover {
  width: 96px; height: 62px; border-radius: 4px; flex: none; overflow: hidden;
  background: linear-gradient(135deg, #1e6ef5, #12b8a6); color: #fff; font-weight: 700;
  display: flex; align-items: center; justify-content: center;
}
.cover img { width: 100%; height: 100%; object-fit: cover; }
.main { flex: 1; min-width: 0; }
.t { font-size: 14px; font-weight: 600; }
.meta { display: flex; justify-content: space-between; align-items: center; margin-top: 8px; font-size: 12px; color: var(--el-text-color-secondary); }
.price { color: var(--el-color-danger); font-weight: 600; }
.ops { margin-top: 10px; text-align: right; }
.pager { margin-top: 12px; justify-content: center; }
.ellipsis2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
</style>
