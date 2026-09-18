<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '../../api'

const loading = ref(false)
const list = ref([])

async function load() {
  loading.value = true
  try {
    list.value = (await adminApi.projects()) || []
  } finally {
    loading.value = false
  }
}

// ---- 编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({ code: '', name: '', subject_label: '科目', logo: '', description: '', sort: 0, status: 'active' })

function openCreate() {
  editingId.value = 0
  Object.assign(form, { code: '', name: '', subject_label: '科目', logo: '', description: '', sort: 0, status: 'active' })
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  Object.assign(form, {
    code: row.code,
    name: row.name,
    subject_label: row.subject_label,
    logo: row.logo,
    description: row.description,
    sort: row.sort,
    status: row.status,
  })
  dlgVisible.value = true
}

async function submit() {
  if (!/^[a-z0-9][a-z0-9-]{1,31}$/.test(form.code)) {
    ElMessage.warning('专业代码需为 2-32 位小写字母/数字，可含中划线且不能开头')
    return
  }
  if (!form.name.trim()) {
    ElMessage.warning('请输入专业名称')
    return
  }
  const payload = {
    code: form.code.trim(),
    name: form.name.trim(),
    subject_label: form.subject_label.trim() || '科目',
    logo: form.logo.trim(),
    description: form.description.trim(),
    sort: form.sort || 0,
    status: form.status,
  }
  saving.value = true
  try {
    if (editingId.value) await adminApi.updateProject(editingId.value, payload)
    else await adminApi.createProject(payload)
    ElMessage.success('已保存')
    dlgVisible.value = false
    await load()
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(
    `确定删除专业「${row.name}」吗？其根分类会一并隐藏；树内还有科目或内容时无法删除。`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteProject(row.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

// Logo 走题目图片上传通道（/admin/upload-image → { url }）
const fileRef = ref(null)
async function onLogoFile(ev) {
  const file = ev.target.files?.[0]
  ev.target.value = ''
  if (!file) return
  try {
    const d = await adminApi.uploadImage(file)
    form.logo = d.url
  } catch {}
}

onMounted(load)
</script>

<template>
  <div class="page-list">
    <div class="toolbar">
      <el-button type="primary" @click="openCreate">新建专业</el-button>
      <span class="hint">专业 = 一棵分类子树（如：二级建造师 / 土木工程 / 财会金融）。创建后自动建根分类，科目在「分类管理」里维护。</span>
    </div>

    <div class="table-wrap">
      <el-table v-loading="loading" :data="list" height="100%">
        <el-table-column prop="id" label="ID" width="70" />
        <el-table-column label="Logo" width="80">
          <template #default="{ row }">
            <el-image v-if="row.logo" :src="row.logo" fit="cover" class="logo-img" />
            <span v-else class="hint">—</span>
          </template>
        </el-table-column>
        <el-table-column prop="name" label="专业名称" min-width="160" show-overflow-tooltip />
        <el-table-column prop="code" label="代码" min-width="120" show-overflow-tooltip />
        <el-table-column prop="subject_label" label="科目别称" width="100" />
        <el-table-column label="简介" min-width="200" show-overflow-tooltip>
          <template #default="{ row }">
            <span class="hint">{{ row.description || '—' }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="sort" label="排序" width="70" />
        <el-table-column label="状态" width="90">
          <template #default="{ row }">
            <el-tag :type="row.status === 'active' ? 'success' : 'info'" size="small">
              {{ row.status === 'active' ? '启用' : '停用' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="root_category_id" label="根分类" width="80" />
        <el-table-column label="操作" width="150" fixed="right">
          <template #default="{ row }">
            <el-button size="small" @click="openEdit(row)">编辑</el-button>
            <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
          </template>
        </el-table-column>
        <template #empty>
          <el-empty description="暂无专业，先创建一个（如：二级建造师 / 土木工程）" />
        </template>
      </el-table>
    </div>

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑专业' : '新建专业'" width="520">
      <el-form label-width="90px">
        <el-form-item label="专业代码" required>
          <el-input v-model="form.code" :maxlength="32" placeholder="小写字母/数字，如 yishi、erjian" />
        </el-form-item>
        <el-form-item label="专业名称" required>
          <el-input v-model="form.name" :maxlength="64" show-word-limit placeholder="如：二级建造师 / 土木工程 / 财会金融" />
        </el-form-item>
        <el-form-item label="科目别称">
          <el-input v-model="form.subject_label" :maxlength="16" placeholder="默认「科目」，可填：章节 / 专业实务 等" />
        </el-form-item>
        <el-form-item label="Logo">
          <el-input v-model="form.logo" :maxlength="512" placeholder="图片 URL，或点右侧上传">
            <template #append>
              <el-button @click="fileRef?.click()">上传</el-button>
            </template>
          </el-input>
          <input ref="fileRef" type="file" accept="image/*" hidden @change="onLogoFile" />
        </el-form-item>
        <el-form-item label="简介">
          <el-input v-model="form.description" type="textarea" :rows="3" :maxlength="2000" show-word-limit />
        </el-form-item>
        <el-form-item label="排序">
          <el-input-number v-model="form.sort" :min="0" controls-position="right" />
          <span class="hint">数字小靠前</span>
        </el-form-item>
        <el-form-item v-if="editingId" label="状态">
          <el-radio-group v-model="form.status">
            <el-radio-button value="active">启用</el-radio-button>
            <el-radio-button value="disabled">停用</el-radio-button>
          </el-radio-group>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dlgVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="submit">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.page-list { flex: 1; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; flex: none; align-items: center; }
.table-wrap { flex: 1; min-height: 0; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.logo-img { width: 36px; height: 36px; border-radius: 6px; display: block; }
</style>
