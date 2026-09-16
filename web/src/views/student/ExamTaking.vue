<script setup>
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { examApi } from '../../api'
import QuestionCard from '../../components/QuestionCard.vue'

const props = defineProps({ attemptId: { type: String, default: '' } })
const router = useRouter()

const loadErr = ref('')
const exam = ref(null)
const attemptId = ref(0)
const questions = ref([])
const answers = reactive({}) // question_id -> answer 字符串
const remaining = ref(0)

let timer = null
let saveTimer = null
let submitted = false

// 交卷/保存均提交全量非空答案（服务端语义：整体替换快照 answers）
function entries() {
  return questions.value
    .filter((q) => answers[q.id])
    .map((q) => ({ question_id: q.id, answer: answers[q.id] }))
}

const answeredCount = computed(() => questions.value.filter((q) => answers[q.id]).length)
const pct = computed(() =>
  questions.value.length ? Math.round((answeredCount.value * 100) / questions.value.length) : 0,
)

function fmt(sec) {
  const p = (n) => String(n).padStart(2, '0')
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  return h ? `${p(h)}:${p(m)}:${p(sec % 60)}` : `${p(m)}:${p(sec % 60)}`
}

function setAnswer(qid, v) {
  answers[qid] = v
  // 30s debounce 自动保存；倒计时归零也会兜底保存
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(save, 30000)
}

async function save() {
  if (submitted) return
  await examApi.saveAnswers(attemptId.value, entries()).catch(() => {})
}

function cleanup() {
  if (timer) { clearInterval(timer); timer = null }
  if (saveTimer) { clearTimeout(saveTimer); saveTimer = null }
}

async function doSubmit(skipConfirm = false) {
  if (submitted) return
  if (!skipConfirm) {
    const left = questions.value.length - answeredCount.value
    if (left > 0) {
      const ok = await ElMessageBox.confirm(`还有 ${left} 题未作答，确定交卷吗？`, '确认交卷', { type: 'warning' })
        .then(() => true)
        .catch(() => false)
      if (!ok) return
    }
  }
  submitted = true
  cleanup()
  const r = await examApi.submit(attemptId.value, entries()).catch(() => null)
  if (!r) {
    submitted = false
    return // 交卷请求失败，允许重试
  }
  sessionStorage.removeItem(`exam_${attemptId.value}`)
  router.replace(`/exam-attempts/${attemptId.value}`)
}

function scrollTo(i) {
  document.getElementById(`q${i}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function onUnload(e) {
  if (!submitted) {
    e.preventDefault()
    e.returnValue = ''
  }
}

onMounted(() => {
  attemptId.value = Number(props.attemptId)
  const raw = sessionStorage.getItem(`exam_${attemptId.value}`)
  if (!raw) {
    loadErr.value = '考试数据已失效（浏览器标签关闭过久或手动清了缓存），请回考试中心继续考试'
    return
  }
  const d = JSON.parse(raw)
  exam.value = d.exam
  questions.value = d.questions
  remaining.value = d.remaining_sec
  for (const q of d.questions) {
    const hit = (d.answers || []).find((a) => a.question_id === q.id)
    answers[q.id] = hit ? hit.answer : ''
  }
  if (d.resumed) ElMessage.info('已恢复上次未完成的作答')

  timer = setInterval(() => {
    remaining.value -= 1
    if (remaining.value <= 0) {
      ElMessage.warning('考试时间到，正在自动交卷…')
      doSubmit(true)
    }
  }, 1000)
  window.addEventListener('beforeunload', onUnload)
})

onUnmounted(() => {
  cleanup()
  window.removeEventListener('beforeunload', onUnload)
})
</script>

<template>
  <div>
    <template v-if="loadErr">
      <el-result icon="warning" :sub-title="loadErr" />
      <div class="center"><el-button type="primary" @click="router.push('/exams')">返回考试中心</el-button></div>
    </template>

    <el-row v-else-if="exam" :gutter="16">
      <el-col :span="17">
        <el-card v-for="(q, i) in questions" :id="`q${i}`" :key="q.id" class="q" shadow="never">
          <QuestionCard
            :q="q"
            :model-value="answers[q.id]"
            :index="i + 1"
            :score="q.score"
            @update:model-value="(v) => setAnswer(q.id, v)"
          />
        </el-card>
        <div class="center">
          <el-button type="danger" size="large" @click="doSubmit(false)">交 卷</el-button>
        </div>
      </el-col>

      <el-col :span="7">
        <div class="side">
          <el-card shadow="never">
            <div class="cd-label">{{ exam.title }} · 剩余时间</div>
            <div class="cd" :class="{ warn: remaining <= 300 }">{{ fmt(Math.max(0, remaining)) }}</div>
            <el-progress :percentage="pct" :stroke-width="8" />
            <div class="hint">已答 {{ answeredCount }}/{{ questions.length }} · 每答一题 30 秒后自动保存</div>
            <div class="nav">
              <el-button
                v-for="(q, i) in questions"
                :key="q.id"
                size="small"
                :type="answers[q.id] ? 'primary' : 'default'"
                @click="scrollTo(i)"
              >
                {{ i + 1 }}
              </el-button>
            </div>
            <el-button type="danger" class="submit" @click="doSubmit(false)">交 卷</el-button>
          </el-card>
        </div>
      </el-col>
    </el-row>

    <div v-else v-loading="true" style="height: 300px" />
  </div>
</template>

<style scoped>
.q { margin-bottom: 12px; scroll-margin-top: 70px; }
.center { text-align: center; margin: 16px 0; }
.side { position: sticky; top: 70px; }
.cd-label { font-size: 13px; color: var(--el-text-color-secondary); }
.cd { font-size: 34px; font-weight: 700; font-variant-numeric: tabular-nums; margin: 6px 0 10px; }
.cd.warn { color: var(--el-color-danger); }
.hint { font-size: 12px; color: var(--el-text-color-secondary); margin: 8px 0 10px; }
.nav {
  display: grid; grid-template-columns: repeat(6, 1fr); gap: 6px; margin-bottom: 12px;
}
.nav :deep(.el-button) { margin: 0; width: 100%; }
.submit { width: 100%; }
</style>
