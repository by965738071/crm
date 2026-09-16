<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '../../api'
import { duration } from '../../utils'

const props = defineProps({ id: { type: String, required: true } })
const courseId = Number(props.id)
const router = useRouter()

const loading = ref(false)
const course = ref(null)
const chapters = ref([])

const contentTypeMap = {
  video: { label: '视频', type: 'primary' },
  audio: { label: '音频', type: 'primary' },
  pdf: { label: 'PDF', type: 'warning' },
  markdown: { label: 'Markdown', type: 'success' },
  rich: { label: '富文本', type: 'success' },
}

async function load() {
  loading.value = true
  try {
    const r = await adminApi.course(courseId)
    course.value = r.course
    chapters.value = r.chapters || []
  } catch {} finally {
    loading.value = false
  }
}

// ---- 章节弹窗 ----
const chVisible = ref(false)
const chSaving = ref(false)
const chEditingId = ref(0)
const chForm = reactive({ title: '', sort: 0 })

function openChapter(ch) {
  chEditingId.value = ch ? ch.id : 0
  chForm.title = ch ? ch.title : ''
  chForm.sort = ch ? ch.sort : 0
  chVisible.value = true
}

async function submitChapter() {
  const title = chForm.title.trim()
  if (!title) {
    ElMessage.warning('请输入章节标题')
    return
  }
  chSaving.value = true
  try {
    const body = { course_id: courseId, title, sort: chForm.sort || 0 }
    if (chEditingId.value) await adminApi.updateChapter(chEditingId.value, body)
    else await adminApi.createChapter(body)
    ElMessage.success('已保存')
    chVisible.value = false
    await load()
  } catch {} finally {
    chSaving.value = false
  }
}

async function removeChapter(ch) {
  const ok = await ElMessageBox.confirm(
    `确定删除章节「${ch.title}」吗？其下课时将一并软删。`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteChapter(ch.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

// ---- 课时弹窗 ----
const leVisible = ref(false)
const leSaving = ref(false)
const leEditingId = ref(0)
const leForm = reactive({
  chapter_id: 0,
  title: '',
  content_type: 'markdown',
  resource_id: 0,
  content: '',
  duration: 0,
  is_free: 0,
  sort: 0,
})

// 仅 markdown/富文本课时用 content 字段承载正文
const showContent = computed(() => leForm.content_type === 'markdown' || leForm.content_type === 'rich')

function openLesson(ch, le) {
  leEditingId.value = le ? le.id : 0
  Object.assign(leForm, {
    chapter_id: ch.id,
    title: le ? le.title : '',
    content_type: le ? le.content_type : 'markdown',
    resource_id: le ? le.resource_id : 0,
    content: le ? le.content : '',
    duration: le ? le.duration : 0,
    is_free: le ? le.is_free : 0,
    sort: le ? le.sort : 0,
  })
  leVisible.value = true
}

async function submitLesson() {
  const title = leForm.title.trim()
  if (!title) {
    ElMessage.warning('请输入课时标题')
    return
  }
  leSaving.value = true
  try {
    const body = {
      course_id: courseId,
      chapter_id: leForm.chapter_id,
      title,
      content_type: leForm.content_type,
      resource_id: leForm.resource_id || 0,
      content: leForm.content,
      duration: leForm.duration || 0,
      is_free: leForm.is_free ? 1 : 0,
      sort: leForm.sort || 0,
    }
    if (leEditingId.value) await adminApi.updateLesson(leEditingId.value, body)
    else await adminApi.createLesson(body)
    ElMessage.success('已保存')
    leVisible.value = false
    await load()
  } catch {} finally {
    leSaving.value = false
  }
}

async function removeLesson(le) {
  const ok = await ElMessageBox.confirm(
    `确定删除课时「${le.title}」吗？`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteLesson(le.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

onMounted(load)
</script>
<template>
  <div v-loading="loading">
    <div class="page-hd">
      <el-button text @click="router.push('/admin/courses')">
        <el-icon><ArrowLeft /></el-icon>返回课程列表
      </el-button>
      <template v-if="course">
        <h3 class="course-title">{{ course.title }}</h3>
        <el-tag size="small" :type="course.status === 'published' ? 'success' : 'info'">
          {{ course.status === 'published' ? '已上架' : '草稿' }}
        </el-tag>
      </template>
      <el-button class="create-btn" type="primary" @click="openChapter(null)">新增章节</el-button>
    </div>

    <el-empty v-if="!loading && !chapters.length" description="暂无章节，先创建一个章节"
      :image-size="80" />

    <el-card v-for="ch in chapters" :key="ch.id" class="ch-card" shadow="never">
      <template #header>
        <div class="ch-hd">
          <span class="ch-title">{{ ch.title }}</span>
          <el-tag size="small" type="info">排序 {{ ch.sort }}</el-tag>
          <div class="ch-ops">
            <el-button size="small" type="primary" plain @click="openLesson(ch, null)">新增课时</el-button>
            <el-button size="small" @click="openChapter(ch)">编辑</el-button>
            <el-button size="small" type="danger" plain @click="removeChapter(ch)">删除</el-button>
          </div>
        </div>
      </template>

      <el-table :data="ch.lessons" size="small" stripe>
        <el-table-column prop="id" label="ID" width="64" />
        <el-table-column prop="title" label="课时标题" min-width="180" show-overflow-tooltip />
        <el-table-column label="类型" width="96">
          <template #default="{ row }">
            <el-tag size="small" :type="contentTypeMap[row.content_type]?.type || 'info'">
              {{ contentTypeMap[row.content_type]?.label || row.content_type }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="关联资源" width="90">
          <template #default="{ row }">{{ row.resource_id || '-' }}</template>
        </el-table-column>
        <el-table-column label="时长" width="80">
          <template #default="{ row }">{{ row.duration ? duration(row.duration) : '-' }}</template>
        </el-table-column>
        <el-table-column label="免费试看" width="90">
          <template #default="{ row }">
            <el-tag v-if="row.is_free" size="small" type="success">免费</el-tag>
            <span v-else>-</span>
          </template>
        </el-table-column>
        <el-table-column prop="sort" label="排序" width="70" />
        <el-table-column label="操作" width="140" fixed="right">
          <template #default="{ row }">
            <el-button size="small" @click="openLesson(ch, row)">编辑</el-button>
            <el-button size="small" type="danger" plain @click="removeLesson(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>
      <div v-if="!ch.lessons.length" class="no-lesson">该章节下暂无课时</div>
    </el-card>

    <el-dialog v-model="chVisible" :title="chEditingId ? '编辑章节' : '新增章节'" width="460">
      <el-form label-width="70px">
        <el-form-item label="标题" required>
          <el-input v-model="chForm.title" :maxlength="200" placeholder="章节标题" />
        </el-form-item>
        <el-form-item label="排序">
          <el-input-number v-model="chForm.sort" :min="0" controls-position="right" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="chVisible = false">取消</el-button>
        <el-button type="primary" :loading="chSaving" @click="submitChapter">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="leVisible" :title="leEditingId ? '编辑课时' : '新增课时'" width="620">
      <el-form label-width="90px">
        <el-form-item label="标题" required>
          <el-input v-model="leForm.title" :maxlength="200" placeholder="课时标题" />
        </el-form-item>
        <el-form-item label="内容类型">
          <el-select v-model="leForm.content_type" class="w180">
            <el-option v-for="(v, k) in contentTypeMap" :key="k" :label="v.label" :value="k" />
          </el-select>
        </el-form-item>
        <el-form-item label="关联资源 ID">
          <el-input-number v-model="leForm.resource_id" :min="0" controls-position="right" />
          <span class="hint">0 = 不关联；视频/音频/PDF 课时需在资料库上传后填入</span>
        </el-form-item>
        <el-form-item label="时长（秒）">
          <el-input-number v-model="leForm.duration" :min="0" :step="60" controls-position="right" />
        </el-form-item>
        <el-form-item v-if="showContent" label="正文">
          <el-input v-model="leForm.content" type="textarea" :rows="8"
            :placeholder="leForm.content_type === 'markdown' ? '支持 Markdown' : '支持 HTML 富文本'" />
        </el-form-item>
        <el-form-item label="免费试看">
          <el-switch v-model="leForm.is_free" :active-value="1" :inactive-value="0" />
        </el-form-item>
        <el-form-item label="排序">
          <el-input-number v-model="leForm.sort" :min="0" controls-position="right" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="leVisible = false">取消</el-button>
        <el-button type="primary" :loading="leSaving" @click="submitLesson">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.page-hd { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
.course-title { margin: 0; font-size: 17px; }
.create-btn { margin-left: auto; }
.ch-card { margin-bottom: 14px; }
.ch-hd { display: flex; align-items: center; gap: 10px; }
.ch-title { font-weight: 600; }
.ch-ops { margin-left: auto; }
.no-lesson { padding: 8px 2px; font-size: 13px; color: var(--el-text-color-secondary); }
.w180 { width: 180px; }
.hint { margin-left: 10px; font-size: 12px; color: var(--el-text-color-secondary); }
</style>
