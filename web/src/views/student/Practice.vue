<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { categoryApi, practiceApi } from '../../api'
import { useProjectStore } from '../../stores/project'
import QuestionCard from '../../components/QuestionCard.vue'

const project = useProjectStore()
const cats = ref([])
const catProps = { label: 'name', value: 'id', children: 'children' }

const cfg = reactive({ mode: 'chapter', category_id: undefined, count: 10 })
const starting = ref(false)

// quiz 项：{ q, answer, feedback, submitting }
const quiz = ref([])
const started = ref(false)
const favIds = ref(new Set())
let startTs = 0

async function start() {
  if (cfg.mode === 'chapter' && !cfg.category_id) return ElMessage.warning('章节练习需选择题目分类')
  starting.value = true
  try {
    const d = await practiceApi.start({
      mode: cfg.mode,
      ...project.scope(cfg.category_id),
      count: cfg.count,
    })
    if (!d.items.length) return ElMessage.warning('该范围没有足够题目，换个分类或减少题数')
    quiz.value = d.items.map((q) => ({ q, answer: '', feedback: null, submitting: false }))
    started.value = true
    startTs = Date.now()
    // 收藏按钮初始状态：取前 100 条收藏做集合（v1 足够）
    const f = await practiceApi.favQuestions({ page: 1, size: 100 }).catch(() => null)
    favIds.value = new Set((f?.items || []).map((x) => x.question.id))
    window.scrollTo(0, 0)
  } catch {
  } finally {
    starting.value = false
  }
}

const answeredCount = computed(() => quiz.value.filter((x) => x.feedback).length)
const correctCount = computed(() => quiz.value.filter((x) => x.feedback && x.feedback.correct).length)
const allDone = computed(() => started.value && answeredCount.value === quiz.value.length)

async function submitOne(row) {
  if (!row.answer) return ElMessage.warning('请先作答')
  row.submitting = true
  try {
    row.feedback = await practiceApi.submit({
      question_id: row.q.id,
      answer: row.answer,
      duration: Math.max(1, Math.round((Date.now() - startTs) / 1000 / quiz.value.length)),
      source: cfg.mode === 'random' ? 'random' : 'chapter',
    })
  } catch {
  } finally {
    row.submitting = false
  }
}

async function toggleFav(row) {
  const d = await practiceApi.toggleFavQuestion(row.q.id)
  const s = new Set(favIds.value)
  if (d.favorited) s.add(row.q.id)
  else s.delete(row.q.id)
  favIds.value = s
}

async function loadCats() {
  const params = project.currentId ? { project_id: project.currentId } : undefined
  cats.value = await categoryApi.tree(params).catch(() => [])
}

onMounted(loadCats)

watch(
  () => project.currentId,
  () => {
    cfg.category_id = undefined
    loadCats()
  },
)
</script>

<template>
  <div>
    <el-card shadow="never" class="cfg">
      <div class="cfg-row">
        <el-radio-group v-model="cfg.mode">
          <el-radio-button value="chapter">按分类练习</el-radio-button>
          <el-radio-button value="random">随机抽题</el-radio-button>
        </el-radio-group>
        <el-tree-select
          v-if="cfg.mode === 'chapter'"
          v-model="cfg.category_id"
          :data="cats"
          :props="catProps"
          node-key="id"
          check-strictly
          clearable
          placeholder="选择题目分类"
          style="width: 220px"
        />
        <span class="lbl">题数</span>
        <el-input-number v-model="cfg.count" :min="1" :max="50" />
        <el-button type="primary" :loading="starting" @click="start">
          {{ started ? '换一组题' : '开始练习' }}
        </el-button>
      </div>
    </el-card>

    <template v-if="started">
      <el-alert
        v-if="allDone"
        class="summary"
        :type="correctCount === quiz.length ? 'success' : 'info'"
        :closable="false"
        show-icon
        :title="`本轮完成：${answeredCount} 题，答对 ${correctCount} 题（正确率 ${Math.round((correctCount * 100) / quiz.length)}%）`"
      >
        <el-button size="small" type="primary" class="again" @click="start">再来一轮</el-button>
      </el-alert>

      <el-card v-for="(row, i) in quiz" :key="row.q.id" class="q" shadow="never">
        <QuestionCard
          v-model="row.answer"
          :q="row.q"
          :index="i + 1"
          :disabled="!!row.feedback"
          :feedback="row.feedback"
          show-fav
          :fav="favIds.has(row.q.id)"
          @toggle-fav="toggleFav(row)"
        />
        <div v-if="!row.feedback" class="sub">
          <el-button type="primary" size="small" :loading="row.submitting" @click="submitOne(row)">
            提交本题答案
          </el-button>
        </div>
      </el-card>
    </template>

    <el-empty v-else description="选择模式与范围，开始一组练习" />
  </div>
</template>

<style scoped>
.cfg { margin-bottom: 14px; }
.cfg-row { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.lbl { font-size: 14px; color: var(--el-text-color-secondary); }
.summary { margin-bottom: 14px; }
.again { margin-left: 10px; }
.q { margin-bottom: 12px; }
.sub { margin-top: 8px; text-align: right; }
</style>
