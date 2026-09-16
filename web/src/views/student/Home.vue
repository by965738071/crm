<script setup>
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '../../stores/auth'
import { announcementApi, courseApi } from '../../api'
import { money, date } from '../../utils'

const router = useRouter()
const auth = useAuthStore()
const anns = ref([])
const courses = ref([])
const loading = ref(true)

onMounted(async () => {
  try {
    const [a, c] = await Promise.all([
      announcementApi.list({ page: 1, size: 5 }),
      courseApi.list({ page: 1, size: 10 }),
    ])
    anns.value = a.items
    courses.value = c.items
  } catch {
    /* 拦截器已提示 */
  } finally {
    loading.value = false
  }
})

const tipCourse = computed(() => courses.value[0])

const quickEntries = [
  { title: '在线课程', desc: '系统化备考', icon: 'Reading', path: '/courses', from: '#1e6ef5', to: '#4b8bf7' },
  { title: '智能题库', desc: '专项刷题', icon: 'EditPen', path: '/practice', from: '#12b8a6', to: '#2bd4be' },
  { title: '模拟考试', desc: '实战演练', icon: 'Trophy', path: '/exams', from: '#f59e0b', to: '#fbbf24' },
  { title: '错题本', desc: '查漏补缺', icon: 'Collection', path: '/wrong-book', from: '#ef4464', to: '#f56c6c' },
]

const benefits = [
  { icon: 'Calendar', title: '学习日历', desc: '章节划分课时，进度一目了然，轻松安排每日计划' },
  { icon: 'DataAnalysis', title: '数据分析', desc: '做题正确率与错题统计，量化掌握每个知识点' },
  { icon: 'Clock', title: '限时模拟', desc: '与真实考试一致的时长与计分规则，考前全真演练' },
  { icon: 'CollectionTag', title: '错题沉淀', desc: '错题自动收录，一键标记掌握，知识盲区逐一击破' },
]

function openQuick(q) {
  const isPublic = q.path === '/courses'
  if (!auth.isLoggedIn && !isPublic) router.push({ path: '/login', query: { next: q.path } })
  else router.push(q.path)
}

const delay = (i) => ({ animationDelay: `${i * 70}ms` })
</script>

<template>
  <div v-loading="loading">
    <!-- 极光 Hero -->
    <section class="hero rise">
      <div class="blob b1" />
      <div class="blob b2" />
      <div class="blob b3" />
      <div class="hero-inner">
        <div class="hero-copy">
          <span class="badge">
            <span class="dot" />
            医学考试一站式学习平台
          </span>
          <h1 class="hero-title">
            让每一次备考<br />
            <span class="grad-text">都更有把握</span>
          </h1>
          <p class="hero-sub">权威课程体系 · 海量智能题库 · 全真模拟考 <br class="hide-sm" />随时随地，系统性备考</p>
          <div class="hero-actions">
            <el-button size="large" class="hero-btn-primary" @click="router.push('/courses')">开始学习</el-button>
            <el-button size="large" class="hero-btn-ghost" @click="router.push('/register')">
              <el-icon><CirclePlus /></el-icon>免费注册
            </el-button>
          </div>
          <div class="hero-stats">
            <div class="stat">
              <b class="grad-text">{{ courses.length }}</b>
              <span>热门课程</span>
            </div>
            <div class="stat">
              <b class="grad-text">{{ anns.length }}</b>
              <span>最新公告</span>
            </div>
            <div class="stat">
              <b class="grad-text">24h</b>
              <span>随时学习</span>
            </div>
          </div>
        </div>

        <!-- 毛玻璃推荐课程卡 -->
        <div class="hero-side">
          <div v-if="tipCourse" class="glass-card">
            <div class="gc-head">
              <span class="gc-tag">今日推荐</span>
              <span class="gc-price">{{ tipCourse.is_free ? '免费' : money(tipCourse.price) }}</span>
            </div>
            <div class="gc-cover" @click="router.push(`/courses/${tipCourse.id}`)">
              <img v-if="tipCourse.cover" :src="tipCourse.cover" alt="" />
              <span v-else>{{ tipCourse.title.slice(0, 2) }}</span>
            </div>
            <div class="gc-body">
              <div class="gc-title">{{ tipCourse.title }}</div>
              <div class="gc-meta">
                <el-icon><User /></el-icon> {{ tipCourse.enroll_count }} 人在学
                <el-icon style="margin-left: 10px"><Folder /></el-icon> 医学考试
              </div>
              <el-button type="primary" class="gc-btn" @click="router.push(`/courses/${tipCourse.id}`)">
                了解课程 <el-icon class="el-icon--right"><ArrowRight /></el-icon>
              </el-button>
            </div>
          </div>
          <div v-else class="glass-card promise">
            <el-icon :size="40" color="#fff"><Present /></el-icon>
            <div class="pc-title">注册即学</div>
            <div class="pc-sub">免费课程 · 公开资料<br />无需下载任何 App</div>
          </div>
        </div>
      </div>
    </section>

    <!-- 快捷入口 Bento 条 -->
    <section class="quick-sec">
      <el-row :gutter="16">
        <el-col v-for="(q, i) in quickEntries" :key="q.path" :xs="12" :sm="12" :md="6" class="rise" :style="delay(i)">
          <div class="quick" @click="openQuick(q)">
            <span class="qi" :style="{ background: `linear-gradient(135deg, ${q.from}, ${q.to})` }">
              <el-icon :size="22" color="#fff"><component :is="q.icon" /></el-icon>
            </span>
            <div>
              <div class="qt">{{ q.title }}</div>
              <div class="qd">{{ q.desc }}</div>
            </div>
            <el-icon class="arrow"><ArrowRight /></el-icon>
          </div>
        </el-col>
      </el-row>
    </section>

    <!-- 热门课程 -->
    <section class="sec">
      <div class="sec-head rise">
        <div>
          <h3>热门课程</h3>
          <p class="sec-sub">精选优质课程，科学规划备考节奏</p>
        </div>
        <el-button round plain class="more-btn" @click="router.push('/courses')">
          查看全部 <el-icon class="el-icon--right"><ArrowRight /></el-icon>
        </el-button>
      </div>
      <el-row :gutter="20">
        <el-col
          v-for="(c, i) in courses"
          :key="c.id"
          :xs="12"
          :sm="8"
          :md="6"
          :lg="6"
          :xl="4"
          class="rise"
          :style="delay(i)"
        >
          <div class="course-card" @click="router.push(`/courses/${c.id}`)">
            <div class="cover">
              <img v-if="c.cover" :src="c.cover" alt="" />
              <span v-else>{{ c.title.slice(0, 2) }}</span>
            </div>
            <div class="cbody">
              <div class="ct ellipsis">{{ c.title }}</div>
              <div class="meta">
                <span class="price">{{ c.is_free ? '免费' : money(c.price) }}</span>
                <span class="enroll"><el-icon><User /></el-icon> {{ c.enroll_count }}</span>
              </div>
            </div>
          </div>
        </el-col>
      </el-row>
      <el-empty v-if="!loading && !courses.length" description="暂无课程" />
    </section>

    <!-- 公告 + 平台特色 -->
    <el-row :gutter="20">
      <el-col :xs="24" :lg="14" class="rise">
        <section class="sec">
          <div class="sec-head">
            <div>
              <h3>最新公告</h3>
              <p class="sec-sub">平台动态 · 考试资讯 · 功能更新</p>
            </div>
            <el-button round plain class="more-btn" @click="router.push('/announcements')">
              全部公告 <el-icon class="el-icon--right"><ArrowRight /></el-icon>
            </el-button>
          </div>
          <div class="ann-panel">
            <div v-for="a in anns" :key="a.id" class="ann" @click="router.push('/announcements')">
              <span class="ann-idx"><el-icon><Notification /></el-icon></span>
              <span class="a-title ellipsis">{{ a.title }}</span>
              <span class="a-date">{{ date(a.published_at) }}</span>
            </div>
            <el-empty v-if="!loading && !anns.length" :image-size="60" description="暂无公告" />
          </div>
        </section>
      </el-col>

      <el-col :xs="24" :lg="10" class="rise" :style="{ animationDelay: '120ms' }">
        <section class="sec">
          <div class="sec-head">
            <div>
              <h3>为什么选择我们</h3>
              <p class="sec-sub">为医学考试而生的完整闭环</p>
            </div>
          </div>
          <div class="benefits">
            <div v-for="b in benefits" :key="b.title" class="bene">
              <span class="bene-ico"><el-icon :size="18"><component :is="b.icon" /></el-icon></span>
              <div class="bene-main">
                <div class="bene-t">{{ b.title }}</div>
                <div class="bene-d">{{ b.desc }}</div>
              </div>
            </div>
          </div>
        </section>
      </el-col>
    </el-row>
  </div>
</template>

<style scoped>
/* ===== Hero ===== */
.hero {
  position: relative;
  border-radius: 20px;
  overflow: hidden;
  margin-bottom: 24px;
  background: linear-gradient(115deg, #0b2a5e 0%, #0d5bd6 42%, #1e6ef5 70%, #12b8a6 125%);
  min-height: 360px;
}
.blob {
  position: absolute;
  border-radius: 50%;
  filter: blur(70px);
  opacity: 0.55;
  animation: drift 12s ease-in-out infinite alternate;
}
.b1 {
  width: 380px; height: 380px; right: -90px; top: -120px;
  background: radial-gradient(circle, rgba(18, 184, 166, 0.85), transparent 70%);
}
.b2 {
  width: 320px; height: 320px; left: 26%; bottom: -150px;
  background: radial-gradient(circle, rgba(139, 92, 246, 0.6), transparent 70%);
  animation-delay: -4s;
}
.b3 {
  width: 260px; height: 260px; left: -80px; top: 30px;
  background: radial-gradient(circle, rgba(75, 139, 247, 0.9), transparent 70%);
  animation-delay: -8s;
}
@keyframes drift {
  from { transform: translate(0, 0) scale(1); }
  to { transform: translate(20px, 18px) scale(1.12); }
}
.hero-inner {
  position: relative; z-index: 1;
  display: grid;
  grid-template-columns: minmax(0, 1fr) 360px;
  gap: 40px;
  align-items: center;
  padding: 48px 52px;
  color: #fff;
}
.hero-copy .badge {
  display: inline-flex; align-items: center; gap: 8px;
  background: rgba(255, 255, 255, 0.12);
  border: 1px solid rgba(255, 255, 255, 0.22);
  padding: 6px 14px; border-radius: 20px;
  font-size: 13px; letter-spacing: 1px;
  backdrop-filter: blur(6px);
}
.badge .dot { width: 8px; height: 8px; border-radius: 50%; background: #5ce0c3; box-shadow: 0 0 10px #5ce0c3; }
.hero-title { font-size: 42px; font-weight: 800; line-height: 1.3; margin: 18px 0 12px; letter-spacing: 1px; }
.hero-title :deep(.grad-text) {
  background: linear-gradient(90deg, #7fe3d2, #9cc7ff);
  -webkit-background-clip: text; background-clip: text; color: transparent;
}
.hero-sub { font-size: 15px; opacity: 0.85; line-height: 1.8; margin: 0; }
.hero-actions { margin-top: 26px; display: flex; gap: 14px; }
.hero-btn-primary {
  background: #fff; color: #0d5bd6; border: none;
  font-weight: 700; padding: 0 34px; border-radius: 24px;
  box-shadow: 0 12px 26px rgba(0, 0, 0, 0.22);
}
.hero-btn-primary:hover { background: #f0f6ff; color: #0d4fb8; transform: none; }
.hero-btn-ghost {
  background: rgba(255, 255, 255, 0.12); color: #fff;
  border: 1px solid rgba(255, 255, 255, 0.5); border-radius: 24px;
  backdrop-filter: blur(6px);
}
.hero-btn-ghost:hover { background: rgba(255, 255, 255, 0.22); color: #fff; }
.hero-stats { margin-top: 30px; display: flex; gap: 48px; }
.stat b { font-size: 26px; display: block; line-height: 1.2; }
.stat b.grad-text {
  background: linear-gradient(90deg, #7fe3d2, #9cc7ff);
  -webkit-background-clip: text; background-clip: text; color: transparent;
}
.stat span { font-size: 13px; opacity: 0.82; }

/* Hero 右侧毛玻璃卡 */
.hero-side { position: relative; z-index: 2; }
.glass-card {
  background: rgba(255, 255, 255, 0.12);
  border: 1px solid rgba(255, 255, 255, 0.28);
  border-radius: 18px;
  padding: 18px;
  backdrop-filter: blur(14px);
  -webkit-backdrop-filter: blur(14px);
  box-shadow: 0 20px 50px rgba(0, 0, 0, 0.22);
}
.gc-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
.gc-tag {
  font-size: 12px; font-weight: 700; letter-spacing: 1px;
  color: #111; background: #fff; padding: 3px 10px; border-radius: 10px;
}
.gc-price { font-size: 14px; font-weight: 700; }
.gc-cover {
  height: 120px; border-radius: 12px; overflow: hidden; cursor: pointer;
  background: linear-gradient(135deg, rgba(255,255,255,0.25), rgba(255,255,255,0.05));
  display: flex; align-items: center; justify-content: center;
  font-size: 30px; font-weight: 700;
}
.gc-cover img { width: 100%; height: 100%; object-fit: cover; }
.gc-body { padding: 14px 2px 0; }
.gc-title { font-size: 16px; font-weight: 700; line-height: 1.4; }
.gc-meta { font-size: 12px; opacity: 0.85; margin: 8px 0 14px; display: flex; align-items: center; }
.gc-btn { width: 100%; border-radius: 12px; border: none; box-shadow: 0 8px 18px rgba(0, 0, 0, 0.25); }
.glass-card.promise { text-align: center; padding: 34px 20px; }
.pc-title { font-size: 20px; font-weight: 800; margin-top: 12px; }
.pc-sub { font-size: 13px; opacity: 0.85; line-height: 1.8; margin-top: 6px; }

/* ===== 快捷入口 ===== */
.quick-sec { margin-bottom: 30px; }
.quick {
  display: flex; align-items: center; gap: 14px;
  background: #fff;
  border: 1px solid var(--border-soft);
  border-radius: 16px;
  padding: 18px; cursor: pointer; height: 100%;
  transition: box-shadow 0.22s, transform 0.22s;
}
.quick:hover {
  box-shadow: 0 14px 30px rgba(30, 110, 245, 0.13);
  transform: translateY(-3px);
}
.qi {
  width: 48px; height: 48px; border-radius: 14px; flex: none;
  display: flex; align-items: center; justify-content: center;
  box-shadow: 0 6px 14px rgba(30, 110, 245, 0.18);
}
.qt { font-weight: 700; font-size: 15px; }
.qd { font-size: 12px; color: var(--el-text-color-secondary); margin-top: 2px; }
.arrow { margin-left: auto; color: var(--el-text-color-placeholder); transition: transform 0.2s, color 0.2s; }
.quick:hover .arrow { transform: translateX(4px); color: var(--brand); }

/* ===== 区块头 ===== */
.sec { margin-bottom: 34px; }
.sec-head { display: flex; align-items: flex-end; justify-content: space-between; margin: 4px 0 18px; }
.sec-head h3 {
  margin: 0; font-size: 21px; letter-spacing: 0.5px; font-weight: 800;
  display: flex; align-items: center;
}
.sec-head h3::before {
  content: ""; width: 4px; height: 20px; border-radius: 2px;
  background: var(--brand-grad); margin-right: 12px;
}
.sec-sub { margin: 6px 0 0 16px; font-size: 13px; color: var(--el-text-color-secondary); }
.more-btn { border-color: var(--border-soft); color: var(--brand); font-weight: 600; }
.more-btn:hover { border-color: var(--brand); }

/* ===== 课程卡片 ===== */
.course-card {
  cursor: pointer; overflow: hidden;
  background: #fff; border: 1px solid var(--border-soft); border-radius: 16px;
  transition: box-shadow 0.24s, transform 0.24s;
}
.course-card:hover {
  box-shadow: 0 18px 38px rgba(30, 110, 245, 0.14);
  transform: translateY(-5px);
}
.cover {
  position: relative; height: 130px; overflow: hidden;
  background: linear-gradient(135deg, #1e6ef5, #12b8a6);
  color: #fff; font-size: 34px; font-weight: 800;
  display: flex; align-items: center; justify-content: center;
}
.cover img { width: 100%; height: 100%; object-fit: cover; transition: transform 0.35s; }
.course-card:hover .cover img { transform: scale(1.06); }
.cbody { padding: 12px 14px 14px; }
.ct { font-size: 15px; font-weight: 700; letter-spacing: 0.2px; }
.meta {
  display: flex; justify-content: space-between; align-items: center;
  margin-top: 10px; font-size: 12px; color: var(--el-text-color-secondary);
}
.meta .el-icon { vertical-align: -2px; }
.price { color: var(--el-color-danger); font-weight: 700; font-size: 14px; }
.enroll { background: var(--el-color-primary-light-9); color: var(--brand); padding: 3px 10px; border-radius: 12px; font-size: 12px; }

/* ===== 公告 ===== */
.ann-panel {
  background: #fff; border: 1px solid var(--border-soft); border-radius: 16px;
  padding: 6px 22px;
}
.ann {
  display: flex; align-items: center; gap: 14px;
  padding: 15px 4px; border-bottom: 1px dashed #e8eef7; cursor: pointer;
  transition: background 0.15s;
}
.ann:last-child { border-bottom: none; }
.ann:hover { background: #f8fbff; border-radius: 12px; }
.ann-idx {
  flex: none; width: 38px; height: 38px; border-radius: 11px;
  background: var(--brand-grad-soft); color: var(--brand);
  display: flex; align-items: center; justify-content: center;
}
.a-title { flex: 1; min-width: 0; font-size: 14px; font-weight: 500; }
.ann:hover .a-title { color: var(--brand); }
.a-date { flex: none; font-size: 12px; color: var(--el-text-color-placeholder); }

/* ===== 特色 ===== */
.benefits { display: grid; gap: 12px; }
.bene {
  display: flex; gap: 14px; align-items: flex-start;
  background: #fff; border: 1px solid var(--border-soft); border-radius: 16px;
  padding: 16px; transition: box-shadow 0.2s, transform 0.2s;
}
.bene:hover { box-shadow: 0 12px 26px rgba(30, 110, 245, 0.12); transform: translateY(-2px); }
.bene-ico {
  flex: none; width: 42px; height: 42px; border-radius: 12px;
  background: var(--brand-grad); color: #fff;
  display: flex; align-items: center; justify-content: center;
  box-shadow: 0 6px 14px rgba(30, 110, 245, 0.24);
}
.bene-t { font-weight: 700; font-size: 15px; }
.bene-d { font-size: 12px; color: var(--el-text-color-secondary); margin-top: 4px; line-height: 1.7; }

.ellipsis { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

@media (max-width: 1100px) {
  .hero-inner { grid-template-columns: 1fr; padding: 40px 32px; }
  .hero-side { max-width: 380px; }
}
@media (max-width: 720px) {
  .hero-title { font-size: 30px; }
  .hero-stats { gap: 30px; }
  .hero-actions { flex-direction: column; align-items: stretch; }
  .hide-sm { display: none; }
}
</style>