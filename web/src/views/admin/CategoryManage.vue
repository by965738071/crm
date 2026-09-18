<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'

const loading = ref(false)
const treeDataAll = ref([])
const projects = ref([])
const filterProjectId = ref(0)

// 选中专业 = 只看该专业根分类下的子树；专业根节点由专业管理维护，此处禁改
const treeData = computed(() => {
  const p = projects.value.find((x) => x.id === filterProjectId.value)
  if (!p) return treeDataAll.value
  return treeDataAll.value.filter((n) => n.id === p.root_category_id)
})
const projectRootIds = computed(() => new Set(projects.value.map((p) => p.root_category_id)))
const isProjectRoot = (row) => projectRootIds.value.has(row.id)
const curProject = computed(() => projects.value.find((x) => x.id === filterProjectId.value) || null)

async function load() {
  loading.value = true
  try {
    const [t, ps] = await Promise.all([categoryApi.tree(), adminApi.projects()])
    treeDataAll.value = t || []
    projects.value = ps || []
  } finally {
    loading.value = false
  }
}

const treeProps = { label: 'name', value: 'id', children: 'children' }

// ---- 编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({ parent_id: null, name: '', sort: 0 })

function openCreate(parent) {
  editingId.value = 0
  // 选中专业且未指定父级时，默认挂到该专业根分类下
  form.parent_id = parent ? parent.id : curProject.value ? curProject.value.root_category_id : null
  form.name = ''
  form.sort = 0
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  form.parent_id = row.parent_id || null
  form.name = row.name
  form.sort = row.sort
  dlgVisible.value = true
}

async function submit() {
  const name = form.name.trim()
  if (!name) {
    ElMessage.warning('请输入分类名')
    return
  }
  const payload = { parent_id: form.parent_id || 0, name, sort: form.sort || 0 }
  saving.value = true
  try {
    if (editingId.value) await adminApi.updateCategory(editingId.value, payload)
    else await adminApi.createCategory(payload)
    ElMessage.success('已保存')
    dlgVisible.value = false
    await load()
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(
    `确定删除分类「${row.name}」吗？有子分类或引用时无法删除。`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteCategory(row.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

onMounted(load)
</script>

<template>
  <div class="page-list">
    <div class="toolbar">
      <el-select v-model="filterProjectId" class="proj-filter" placeholder="全部专业">
        <el-option label="全部专业" :value="0" />
        <el-option v-for="p in projects" :key="p.id" :label="p.name" :value="p.id" />
      </el-select>
      <el-button type="primary" @click="openCreate(null)">
        {{ curProject ? `在「${curProject.name}」下新增科目` : '新增根分类' }}
      </el-button>
      <span class="hint">专业的创建/改名请去「专业管理」，根分类会随专业自动维护</span>
    </div>

    <div class="table-wrap">
    <el-table v-loading="loading" :data="treeData" row-key="id"
      :tree-props="{ children: 'children' }" height="100%">
      <el-table-column prop="name" label="分类名" min-width="240" show-overflow-tooltip />
      <el-table-column prop="id" label="ID" width="80" />
      <el-table-column prop="sort" label="排序" width="80" />
      <el-table-column label="操作" width="240" fixed="right">
        <template #default="{ row }">
          <el-button size="small" plain @click="openCreate(row)">加子级</el-button>
          <el-button size="small" @click="openEdit(row)" :disabled="isProjectRoot(row)">编辑</el-button>
          <el-button size="small" type="danger" plain @click="remove(row)" :disabled="isProjectRoot(row)">删除</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <el-empty description="暂无分类，先创建根分类" />
      </template>
    </el-table>
    </div>

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑分类' : '新增分类'" width="460">
      <el-form label-width="80px">
        <el-form-item label="上级分类">
          <el-tree-select v-model="form.parent_id" :data="treeData" :props="treeProps" check-strictly
            clearable placeholder="留空 = 根分类" class="w100" />
        </el-form-item>
        <el-form-item label="分类名" required>
          <el-input v-model="form.name" :maxlength="64" show-word-limit placeholder="1-64 字符" />
        </el-form-item>
        <el-form-item label="排序">
          <el-input-number v-model="form.sort" :min="0" controls-position="right" />
          <span class="hint">数字小靠前</span>
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
.proj-filter { width: 180px; }
.table-wrap { flex: 1; min-height: 0; }
.w100 { width: 100%; }
.hint { margin-left: 10px; font-size: 12px; color: var(--el-text-color-secondary); }
</style>
