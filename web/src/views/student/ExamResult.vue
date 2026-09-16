<script setup>
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { examApi } from '../../api'
import { datetime } from '../../utils'
import QuestionCard from '../../components/QuestionCard.vue'

const props = defineProps({ id: { type: String, default: '' } })
const route = useRoute()
const router = useRouter()

const loading = ref(false)
const detail = ref(null)

async function load() {
  loading.value = true
  try {
    detail.value = await examApi.attemptDetail(Number(props.id || route.params.id))
  } catch {
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <div v-loading="loading">
    <template v-if="detail">
      <el-card shadow="never" class="head">
        <div class="title-row">
          <div>
            <div class="title">{{ detail.exam_title }}</div>
            <div class="meta">
              开始 {{ datetime(detail.started_at) }} · 交卷 {{ datetime(detail.submitted_at) }} ·
              及格线 {{ detail.pass_score }} 分
            </div>
          </div>
          <div class="score-box">
            <div class="score" :class="{ pass: detail.passed }">{{ detail.score }}</div>
            <div class="total">/ {{ detail.total_score }}</div>
          </div>
        </div>
        <div class="tags">
          <el-tag :type="detail.passed ? 'success' : 'danger'" size="large">
            {{ detail.passed ? '通过' : '未通过' }}
          </el-tag>
          <el-tag type="info" size="large">答对 {{ detail.correct_count }}/{{ detail.total_count }}</el-tag>
        </div>
      </el-card>

      <el-divider content-position="left">逐题回顾</el-divider>

      <el-card v-for="(it, i) in detail.items" :key="it.question_id" class="item" shadow="never">
        <QuestionCard
          :q="{ id: it.question_id, type: it.type, stem: it.stem, options: it.options, answer: it.answer, explanation: it.explanation }"
          :model-value="it.student_answer"
          disabled
          show-answer
          :index="i + 1"
          :score="it.score"
        />
        <div class="gained">
          <el-tag size="small" :type="it.correct ? 'success' : 'danger'">
            {{ it.correct ? `+${it.score_gained} 分` : `本题作答${it.student_answer ? '错误' : '未作答'}` }}
          </el-tag>
        </div>
      </el-card>

      <div class="back">
        <el-button @click="router.push('/exams')">返回考试中心</el-button>
      </div>
    </template>
    <el-empty v-else-if="!loading" description="考试记录不存在或尚未交卷">
      <el-button type="primary" @click="router.push('/exams')">返回考试中心</el-button>
    </el-empty>
  </div>
</template>

<style scoped>
.head { margin-bottom: 16px; }
.title-row { display: flex; justify-content: space-between; align-items: flex-start; }
.title { font-size: 18px; font-weight: 700; }
.meta { font-size: 12px; color: var(--el-text-color-secondary); margin-top: 6px; }
.score-box { display: flex; align-items: baseline; gap: 4px; }
.score { font-size: 40px; font-weight: 700; color: var(--el-color-danger); }
.score.pass { color: var(--el-color-success); }
.total { font-size: 16px; color: var(--el-text-color-secondary); }
.tags { margin-top: 14px; display: flex; gap: 8px; }
.item { margin-bottom: 12px; }
.gained { margin-top: 6px; }
.back { text-align: center; margin: 16px 0; }
</style>
