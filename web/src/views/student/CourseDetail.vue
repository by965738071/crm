<script setup>
import { onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import { courseApi, learningApi, favoriteApi } from '../../api'
import { useAuthStore } from '../../stores/auth'
import { money, duration } from '../../utils'

const props = defineProps({ id: { type: String, default: '' } })
const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

const loading = ref(false)
const course = ref(null)
const chapters = ref([])
const enrolled = ref(false)
const payStatus = ref('')
const favorited = ref(false)

const courseId = () => Number(props.id || route.params.id)

async function load() {
  loading.value = true
  try {
    const d = await courseApi.detail(courseId())
    course.value = d.course
    chapters.value = d.chapters || []
    if (auth.isLoggedIn) {
      const r = await learningApi.myEnrollments({ page: 1, size: 100 }).catch(() => null)
      const hit = r?.items?.find((x) => x.course_id === courseId())
      if (hit) {
        enrolled.value = true // 有报名行即已报名（paid/unpaid）；课时锁由后端 locked 字段决定
        payStatus.value = hit.pay_status
      }
      const f = await favoriteApi.list({ target_type: 'course', page: 1, size: 100 }).catch(() => null)
      favorited.value = !!f?.items?.some((x) => x.target_id === courseId())
    }
  } finally {
    loading.value = false
  }
}

async function enroll() {
  if (!auth.isLoggedIn) return router.push({ path: '/login', query: { next: route.fullPath } })
  const r = await courseApi.enroll(courseId())
  if (r.status === 'pending_payment') {
    ElMessage.warning(`已生成订单（${money(r.amount)}），请联系管理员线下支付`)
    router.push('/me/orders')
  } else {
    ElMessage.success('报名成功')
    load()
  }
}

async function toggleFav() {
  if (!auth.isLoggedIn) return router.push({ path: '/login', query: { next: route.fullPath } })
  if (favorited.value) {
    await favoriteApi.remove('course', courseId())
    favorited.value = false
    ElMessage.success('已取消收藏')
  } else {
    await favoriteApi.add({ target_type: 'course', target_id: courseId() })
    favorited.value = true
    ElMessage.success('已收藏')
  }
}

function onLesson(l) {
  if (l.locked) {
    ElMessage.warning('该课时需报名/付费后学习')
    return
  }
  // 带上 course_id：LessonLearn 直接拉课程详情渲染章节导航（课时→课程无反查接口）
  router.push({ path: `/lessons/${l.id}`, query: { course_id: courseId() } })
}

onMounted(load)
</script>

<template>
  <div v-loading="loading">
    <el-page-header content="课程详情" @back="router.back()" />
    <template v-if="course">
      <el-card class="info">
        <div class="head">
          <div class="cover">
            <img v-if="course.cover" :src="course.cover" alt="" />
            <span v-else>{{ course.title.slice(0, 2) }}</span>
          </div>
          <div class="meta">
            <h2>{{ course.title }}</h2>
            <p class="sum">{{ course.summary }}</p>
            <p>
              <el-tag :type="course.is_free ? 'success' : 'danger'" size="small">
                {{ course.is_free ? '免费' : money(course.price) }}
              </el-tag>
              <el-tag type="info" size="small">{{ course.enroll_count }} 人在学</el-tag>
            </p>
            <div class="acts">
              <el-button v-if="!enrolled" type="primary" @click="enroll">
                {{ course.is_free ? '立即报名' : '报名学习' }}
              </el-button>
              <el-button v-else type="success" disabled>
                {{ payStatus === 'paid' ? '已报名' : '已报名（待支付）' }}
              </el-button>
              <el-button :type="favorited ? 'warning' : 'default'" text bg @click="toggleFav">
                <el-icon><Star /></el-icon>{{ favorited ? '已收藏' : '收藏课程' }}
              </el-button>
            </div>
          </div>
        </div>
        <el-collapse v-if="course.description" class="desc">
          <el-collapse-item title="课程介绍">
            <div class="rich">{{ course.description }}</div>
          </el-collapse-item>
        </el-collapse>
      </el-card>

      <el-card class="toc">
        <template #header><b>课程目录</b><span class="hint">共 {{ chapters.length }} 章</span></template>
        <div v-for="ch in chapters" :key="ch.id" class="ch">
          <div class="ch-title">{{ ch.title }}</div>
          <div
            v-for="l in ch.lessons"
            :key="l.id"
            class="ls"
            :class="{ locked: l.locked }"
            @click="onLesson(l)"
          >
            <el-icon><Lock v-if="l.locked" /><VideoPlay v-else /></el-icon>
            <span class="ls-title">{{ l.title }}</span>
            <span class="ls-type">{{ { video: '视频', audio: '音频', pdf: 'PDF', markdown: '图文', rich: '图文' }[l.content_type] || l.content_type }}</span>
            <span v-if="l.duration" class="ls-dur">{{ duration(l.duration) }}</span>
            <el-tag v-if="l.is_free" size="small" type="success">免费</el-tag>
          </div>
        </div>
        <el-empty v-if="!chapters.length" description="暂无课时" :image-size="60" />
      </el-card>
    </template>
  </div>
</template>

<style scoped>
.info { margin-top: 14px; }
.head { display: flex; gap: 20px; }
.cover {
  width: 240px; height: 150px; border-radius: 8px; overflow: hidden; flex-shrink: 0;
  background: linear-gradient(135deg, #1e6ef5, #12b8a6); color: #fff; font-size: 34px; font-weight: 700;
  display: flex; align-items: center; justify-content: center;
}
.cover img { width: 100%; height: 100%; object-fit: cover; }
.meta h2 { margin: 0 0 8px; }
.sum { color: var(--el-text-color-secondary); font-size: 14px; margin: 0 0 10px; }
.meta .el-tag { margin-right: 8px; }
.acts { margin-top: 14px; display: flex; gap: 10px; align-items: center; }
.desc { margin-top: 12px; }
.rich { white-space: pre-wrap; line-height: 1.8; font-size: 14px; }
.toc { margin-top: 14px; }
.hint { margin-left: 10px; font-size: 12px; color: var(--el-text-color-secondary); }
.ch { margin-bottom: 14px; }
.ch-title { font-weight: 600; margin-bottom: 6px; }
.ls {
  display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 6px; cursor: pointer; font-size: 14px;
}
.ls:hover { background: var(--el-fill-color-light); }
.ls.locked { color: var(--el-text-color-secondary); cursor: not-allowed; }
.ls-title { flex: 1; }
.ls-type { font-size: 12px; color: var(--el-text-color-secondary); }
.ls-dur { font-size: 12px; color: var(--el-text-color-secondary); }
</style>
