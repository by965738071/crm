<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { courseApi, learningApi, resourceApi } from '../../api'

const props = defineProps({ id: { type: String, default: '' } })
const route = useRoute()
const router = useRouter()

const lessonId = () => Number(props.id || route.params.id)
const courseId = () => Number(route.query.course_id || 0)

const loading = ref(false)
const notFound = ref('')
const course = ref(null)
const chapters = ref([])
const lessons = ref([]) // 拍平全课时，用于上一/下一课时
const current = ref(null)
const progressMap = ref({}) // lesson_id -> status

const mediaEl = ref(null)
let hbTimer = null
let lastReport = 0
let reported = false

const mediaSrc = computed(() =>
  current.value && current.value.resource_id ? resourceApi.downloadUrl(current.value.resource_id) : '',
)
const isVideo = computed(() => current.value && current.value.content_type === 'video')
const isAudio = computed(() => current.value && current.value.content_type === 'audio')
const isPdf = computed(() => current.value && current.value.content_type === 'pdf')
const isText = computed(
  () => current.value && ['markdown', 'rich'].includes(current.value.content_type),
)

const idx = computed(() => lessons.value.findIndex((x) => current.value && x.id === current.value.id))
const prev = computed(() => lessons.value[idx.value - 1] || null)
const next = computed(() => lessons.value[idx.value + 1] || null)
const myStatus = computed(() => (current.value ? progressMap.value[current.value.id] || '' : ''))

async function load() {
  if (!courseId()) {
    notFound.value = '缺少 course_id 参数，请从「课程详情」或「我的课程」进入学习'
    return
  }
  loading.value = true
  try {
    const d = await courseApi.detail(courseId())
    course.value = d.course
    chapters.value = d.chapters || []
    lessons.value = chapters.value.flatMap((ch) => ch.lessons || [])
    const l = lessons.value.find((x) => x.id === lessonId())
    if (!l) {
      notFound.value = '课时不存在或已删除'
      return
    }
    if (l.locked) {
      notFound.value = '该课时尚未解锁，请先在课程页完成报名/支付'
      return
    }
    current.value = l
    reported = false
    lastReport = 0
    const pg = await learningApi.myProgress(courseId()).catch(() => [])
    const map = {}
    for (const p of pg || []) map[p.lesson_id] = p.status
    progressMap.value = map
    window.scrollTo(0, 0)
  } finally {
    loading.value = false
  }
}

function report(status, position = 0) {
  return learningApi
    .reportProgress({ lesson_id: lessonId(), status, position: Math.floor(position) })
    .catch(() => {})
}

// ---- 媒体：进度上报（10s 节流 in_progress）、结束 completed、播放期 30s 心跳 ----
function onTimeUpdate(e) {
  const now = Date.now()
  if (now - lastReport > 10000) {
    lastReport = now
    report('in_progress', e.target.currentTime)
  }
}
function onEnded() {
  report('completed')
  progressMap.value = { ...progressMap.value, [lessonId()]: 'completed' }
  reported = true
  ElMessage.success('本课时已完成 🎉')
}
function onPlay() {
  stopHeartbeat()
  hbTimer = setInterval(() => {
    const el = mediaEl.value
    if (el && !el.paused) learningApi.heartbeat({ lesson_id: lessonId(), seconds: 30 }).catch(() => {})
  }, 30000)
}
function onPause() {
  stopHeartbeat()
}
function stopHeartbeat() {
  if (hbTimer) {
    clearInterval(hbTimer)
    hbTimer = null
  }
}

async function markCompleted() {
  await report('completed')
  progressMap.value = { ...progressMap.value, [lessonId()]: 'completed' }
  reported = true
  ElMessage.success('已标记完成')
}

function goto(l) {
  if (!l) return
  if (l.locked) return ElMessage.warning('该课时需报名/付费后学习')
  router.push({ path: `/lessons/${l.id}`, query: { course_id: courseId() } })
}

// 同路由切换课时：组件复用，需手动重置并重新拉取
watch(
  () => [route.params.id, route.query.course_id],
  () => {
    if (route.name !== 'lesson') return
    stopHeartbeat()
    current.value = null
    notFound.value = ''
    load()
  },
)

onMounted(load)
onUnmounted(stopHeartbeat)
</script>

<template>
  <div v-loading="loading">
    <el-empty v-if="notFound" :description="notFound">
      <div class="acts">
        <el-button type="primary" @click="router.push('/me/courses')">回到我的课程</el-button>
        <el-button @click="router.push('/courses')">浏览课程</el-button>
      </div>
    </el-empty>

    <el-row v-else-if="current" :gutter="16">
      <el-col :span="17">
        <el-card shadow="never">
          <template #header>
            <div class="head">
              <span class="t">{{ current.title }}</span>
              <el-tag v-if="myStatus === 'completed'" size="small" type="success">已完成</el-tag>
              <el-tag v-else-if="myStatus === 'in_progress'" size="small" type="warning">学习中</el-tag>
            </div>
          </template>

          <video
            v-if="isVideo"
            ref="mediaEl"
            class="player"
            controls
            preload="metadata"
            :src="mediaSrc"
            @timeupdate="onTimeUpdate"
            @ended="onEnded"
            @play="onPlay"
            @pause="onPause"
          />
          <audio
            v-else-if="isAudio"
            ref="mediaEl"
            class="audio"
            controls
            preload="metadata"
            :src="mediaSrc"
            @timeupdate="onTimeUpdate"
            @ended="onEnded"
            @play="onPlay"
            @pause="onPause"
          />
          <div v-else-if="isPdf" class="pdf">
            <el-icon class="pdf-ico"><Document /></el-icon>
            <div>本课时资料为 PDF，下载后离线阅读（系统不直接预览）</div>
            <el-link type="primary" :underline="false" :href="mediaSrc">
              <el-icon><Download /></el-icon>下载资料
            </el-link>
          </div>
          <div v-else-if="isText" class="content">{{ current.content }}</div>
          <el-empty v-else description="该课时暂无内容" />

          <div class="acts">
            <el-button :disabled="!prev" @click="goto(prev)">上一课时</el-button>
            <el-button v-if="myStatus !== 'completed'" type="success" :disabled="reported" @click="markCompleted">
              标记为已完成
            </el-button>
            <el-tag v-else type="success" size="large">本课时已完成</el-tag>
            <el-button type="primary" :disabled="!next" @click="goto(next)">下一课时</el-button>
          </div>
        </el-card>
      </el-col>

      <el-col :span="7">
        <div class="side">
          <el-card shadow="never">
            <template #header>{{ course?.title }} · 目录</template>
            <div v-for="ch in chapters" :key="ch.id" class="ch">
              <div class="ch-t">{{ ch.title }}</div>
              <div
                v-for="l in ch.lessons"
                :key="l.id"
                class="li"
                :class="{ cur: current && l.id === current.id }"
                @click="goto(l)"
              >
                <el-icon v-if="progressMap[l.id] === 'completed'" class="ok"><Select /></el-icon>
                <el-icon v-else-if="l.locked" class="lock"><Lock /></el-icon>
                <el-icon v-else class="dot"><VideoPlay /></el-icon>
                <span class="li-t">{{ l.title }}</span>
              </div>
            </div>
          </el-card>
        </div>
      </el-col>
    </el-row>
  </div>
</template>

<style scoped>
.head { display: flex; align-items: center; gap: 10px; font-size: 16px; font-weight: 600; }
.player { width: 100%; max-height: 480px; background: #000; border-radius: 6px; }
.audio { width: 100%; margin: 12px 0; }
.pdf { text-align: center; padding: 40px 0; color: var(--el-text-color-secondary); }
.pdf-ico { font-size: 48px; color: var(--el-color-danger); display: block; margin: 0 auto 10px; }
.content { white-space: pre-wrap; line-height: 1.9; font-size: 15px; }
.acts {	display: flex; gap: 10px; justify-content: center; margin-top: 18px; }
.side { position: sticky; top: 70px; }
.ch { margin-bottom: 10px; }
.ch-t { font-size: 13px; font-weight: 700; color: var(--el-text-color-secondary); margin: 8px 0 4px; }
.li { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border-radius: 4px; cursor: pointer; font-size: 13px; }
.li:hover { background: var(--el-fill-color-light); }
.li.cur { background: var(--el-color-primary-light-9); color: var(--el-color-primary); font-weight: 600; }
.ok { color: var(--el-color-success); }
.lock { color: var(--el-text-color-placeholder); }
.dot { color: var(--el-text-color-secondary); }
.li-t { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
