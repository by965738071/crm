<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { noteApi } from '../../api'
import { datetime } from '../../utils'

const loading = ref(false)
const items = ref([])

const dlg = ref(false)
const editingId = ref(0) // 0 = 新建
const form = reactive({ course_id: undefined, lesson_id: undefined, content: '' })
const saving = ref(false)

async function load() {
  loading.value = true
  try {
    const r = await noteApi.list({})
    items.value = r.items
  } finally {
    loading.value = false
  }
}

function openCreate() {
  editingId.value = 0
  form.course_id = undefined
  form.lesson_id = undefined
  form.content = ''
  dlg.value = true
}

function openEdit(row) {
  editingId.value = row.id
  form.course_id = row.course_id
  form.lesson_id = row.lesson_id || undefined
  form.content = row.content
  dlg.value = true
}

async function save() {
  if (!form.course_id) return ElMessage.warning('请填写课程 ID')
  if (!form.content.trim()) return ElMessage.warning('笔记内容不能为空')
  saving.value = true
  try {
    const body = { course_id: form.course_id, lesson_id: form.lesson_id || 0, content: form.content }
    if (editingId.value) await noteApi.update(editingId.value, body)
    else await noteApi.create(body)
    dlg.value = false
    ElMessage.success('已保存')
    load()
  } catch {
  } finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm('确定删除这条笔记吗？', '提示', { type: 'warning' })
    .then(() => true)
    .catch(() => false) // 取消
  if (!ok) return
  await noteApi.remove(row.id)
  ElMessage.success('已删除')
  load()
}

onMounted(load)
</script>

<template>
  <div>
    <div class="toolbar">
      <el-button type="primary" @click="openCreate">
        <el-icon><EditPen /></el-icon>新建笔记
      </el-button>
      <span class="tip">笔记按「课程 + 可选课时」组织，课程 ID 可在课程详情页地址栏查看</span>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="course_title" label="课程" min-width="160" show-overflow-tooltip />
      <el-table-column label="课时" min-width="140" show-overflow-tooltip>
        <template #default="{ row }">{{ row.lesson_title || '整体笔记' }}</template>
      </el-table-column>
      <el-table-column prop="content" label="内容" min-width="280" show-overflow-tooltip />
      <el-table-column label="更新时间" width="150">
        <template #default="{ row }">{{ datetime(row.updated_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="130" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openEdit(row)">编辑</el-button>
          <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>
    <el-empty v-if="!loading && !items.length" description="还没有笔记" />

    <el-dialog v-model="dlg" :title="editingId ? '编辑笔记' : '新建笔记'" width="560px">
      <el-form label-width="80px">
        <el-form-item label="课程 ID" required>
          <el-input-number v-model="form.course_id" :min="1" controls-position="right" style="width: 180px" />
        </el-form-item>
        <el-form-item label="课时 ID">
          <el-input-number v-model="form.lesson_id" :min="1" controls-position="right" style="width: 180px" />
          <span class="tip" style="margin-left: 8px">不填 = 课程整体笔记</span>
        </el-form-item>
        <el-form-item label="内容">
          <el-input v-model="form.content" type="textarea" :rows="6" maxlength="4000" show-word-limit />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dlg = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; }
.tip { font-size: 12px; color: var(--el-text-color-secondary); }
</style>
