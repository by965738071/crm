<script setup>
import { onMounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { examApi } from '../../api'
import { useProjectStore } from '../../stores/project'
import { datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const router = useRouter()
const project = useProjectStore()
const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ page: 1, size: 9 })

// 历史记录
const hisLoading = ref(false)
const attempts = ref([])
const hisTotal = ref(0)
const hisQuery = reactive({ page: 1, size: 10 })

async function load() {
  loading.value = true
  try {
    const r = await examApi.list({ ...project.scope(), page: query.page, size: query.size })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

async function loadHistory() {
  hisLoading.value = true
  try {
    const r = await examApi.attempts({ page: hisQuery.page, size: hisQuery.size })
    attempts.value = r.items
    hisTotal.value = r.total
  } finally {
    hisLoading.value = false
  }
}

async function startExam(examId) {
  const d = await examApi.start(examId)
  // 题面快照经 sessionStorage 传给答题页；刷新不丢（浏览器会话内有效），
  // 服务端另有 attempt 行兜底：重新 start 同一场会 resumed=true 返回同样数据
  sessionStorage.setItem(`exam_${d.attempt_id}`, JSON.stringify(d))
  if (d.resumed) ElMessage.info('已恢复上次未完成的作答')
  router.push(`/exam-taking/${d.attempt_id}`)
}

async function resume(row) {
  await startExam(row.exam_id)
}

onMounted(() => {
  load()
  loadHistory()
})

watch(
  () => project.currentId,
  () => {
    query.page = 1
    load()
  },
)
</script>

<template>
  <div>
    <h3 class="sec">可用试卷</h3>
    <div v-loading="loading">
      <el-row :gutter="12">
        <el-col v-for="row in items" :key="row.exam.id" :span="8">
          <el-card class="card" shadow="hover">
            <div class="t ellipsis2">{{ row.exam.title }}</div>
            <div class="meta">
              <span>时长 {{ row.exam.duration_min }} 分钟</span>
              <span>{{ row.exam.question_count }} 题 · 总分 {{ row.exam.total_score }}</span>
              <span>及格 {{ row.exam.pass_score }} 分</span>
            </div>
            <div class="mine">
              已考 {{ row.my_attempts }} 次
              <span v-if="row.my_best_score >= 0" class="best">最佳 {{ row.my_best_score }} 分</span>
              <span v-else class="best">未参加</span>
            </div>
            <el-button type="primary" class="go" :disabled="!row.exam.question_count" @click="startExam(row.exam.id)">
              {{ row.my_attempts ? '再考一次' : '开始考试' }}
            </el-button>
          </el-card>
        </el-col>
      </el-row>
      <el-empty v-if="!loading && !items.length" description="暂无开放中的试卷" />
    </div>
    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="load" />

    <h3 class="sec">考试记录</h3>
    <el-table v-loading="hisLoading" :data="attempts" stripe size="small">
      <el-table-column prop="exam_title" label="试卷" min-width="180" show-overflow-tooltip />
      <el-table-column label="状态" width="100">
        <template #default="{ row }">
          <el-tag v-if="!row.submitted_at" size="small" type="warning">进行中</el-tag>
          <el-tag v-else size="small" :type="row.passed ? 'success' : 'danger'">
            {{ row.passed ? '通过' : '未通过' }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="成绩" width="90">
        <template #default="{ row }">{{ row.submitted_at ? row.score : '-' }}</template>
      </el-table-column>
      <el-table-column prop="question_count" label="题数" width="70" />
      <el-table-column label="开始时间" width="150">
        <template #default="{ row }">{{ datetime(row.started_at) }}</template>
      </el-table-column>
      <el-table-column label="交卷时间" width="150">
        <template #default="{ row }">{{ datetime(row.submitted_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="110" fixed="right">
        <template #default="{ row }">
          <el-button v-if="!row.submitted_at" size="small" type="primary" @click="resume(row)">继续作答</el-button>
          <el-button v-else size="small" @click="router.push(`/exam-attempts/${row.id}`)">成绩回顾</el-button>
        </template>
      </el-table-column>
    </el-table>
    <PaginationBar v-model:page="hisQuery.page" :total="hisTotal" :size="hisQuery.size" @change="loadHistory" />
  </div>
</template>

<style scoped>
.sec { margin: 18px 0 12px; }
.card { margin-bottom: 12px; }
.t { font-size: 15px; font-weight: 600; min-height: 44px; }
.meta { font-size: 12px; color: var(--el-text-color-secondary); line-height: 1.9; margin-top: 6px; }
.mine { font-size: 13px; margin-top: 6px; }
.best { color: var(--el-color-warning); margin-left: 8px; }
.go { margin-top: 10px; width: 100%; }
.ellipsis2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
</style>
