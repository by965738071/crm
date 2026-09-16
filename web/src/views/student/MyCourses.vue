<script setup>
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { learningApi } from '../../api'
import { money, datetime } from '../../utils'

const router = useRouter()
const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ page: 1, size: 10 })

async function load() {
  loading.value = true
  try {
    const r = await learningApi.myEnrollments({ page: query.page, size: query.size })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function pct(row) {
  if (!row.total_lessons) return 0
  return Math.round((row.completed_lessons * 100) / row.total_lessons)
}

// 入口优先级：未支付 → 订单页；有学习记录 → 上次课时；否则进课程详情
function goLearn(row) {
  if (row.pay_status === 'unpaid') router.push('/me/orders')
  else if (row.last_lesson_id)
    router.push({ path: `/lessons/${row.last_lesson_id}`, query: { course_id: String(row.course_id) } })
  else router.push(`/courses/${row.course_id}`)
}

function actionLabel(row) {
  if (row.pay_status === 'unpaid') return '去支付'
  return row.last_lesson_id ? '继续学习' : '开始学习'
}

onMounted(load)
</script>

<template>
  <div>
    <div v-loading="loading">
      <el-card v-for="row in items" :key="row.course_id" class="item" shadow="never">
        <div class="row-flex">
          <div class="cover" @click="router.push(`/courses/${row.course_id}`)">
            <img v-if="row.cover" :src="row.cover" alt="" />
            <span v-else>{{ row.title.slice(0, 2) }}</span>
          </div>
          <div class="main">
            <div class="t">
              {{ row.title }}
              <el-tag v-if="row.course_status !== 'published'" size="small" type="info">已下架</el-tag>
              <el-tag v-if="row.pay_status === 'unpaid'" size="small" type="danger">待支付</el-tag>
              <el-tag v-else-if="row.is_free" size="small" type="success">免费</el-tag>
              <el-tag v-else size="small" type="success">已购 {{ money(row.price) }}</el-tag>
            </div>
            <div class="meta">
              报名于 {{ datetime(row.enrolled_at) }} · {{ row.completed_lessons }}/{{ row.total_lessons }} 课时完成
              <span v-if="row.last_lesson_title"> · 上次学到《{{ row.last_lesson_title }}》</span>
            </div>
            <el-progress :percentage="pct(row)" :stroke-width="8" class="prog" />
          </div>
          <div class="ops">
            <el-button type="primary" @click="goLearn(row)">{{ actionLabel(row) }}</el-button>
          </div>
        </div>
      </el-card>
      <el-empty v-if="!loading && !items.length" description="还没有报名任何课程">
        <el-button type="primary" @click="router.push('/courses')">去逛逛课程</el-button>
      </el-empty>
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
.row-flex { display: flex; gap: 14px; align-items: center; }
.cover {
  width: 140px; height: 84px; border-radius: 6px; flex: none; cursor: pointer; overflow: hidden;
  background: linear-gradient(135deg, #1e6ef5, #12b8a6); color: #fff; font-weight: 700; font-size: 22px;
  display: flex; align-items: center; justify-content: center;
}
.cover img { width: 100%; height: 100%; object-fit: cover; }
.main { flex: 1; min-width: 0; }
.t { font-size: 15px; font-weight: 600; display: flex; align-items: center; gap: 6px; }
.meta { font-size: 12px; color: var(--el-text-color-secondary); margin: 6px 0 8px; }
.prog { max-width: 520px; }
.ops { flex: none; }
.pager { margin-top: 12px; justify-content: center; }
</style>
