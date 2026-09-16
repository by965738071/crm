<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'

const loading = ref(false)
const treeData = ref([])

async function load() {
  loading.value = true
  try {
    treeData.value = (await categoryApi.tree()) || []
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
  form.parent_id = parent ? parent.id : null
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
  <div>
    <div class="toolbar">
      <el-button type="primary" @click="openCreate(null)">新增根分类</el-button>
    </div>

    <el-table v-loading="loading" :data="treeData" row-key="id" default-expand-all
      :tree-props="{ children: 'children' }">
      <el-table-column prop="name" label="分类名" min-width="240" show-overflow-tooltip />
      <el-table-column prop="id" label="ID" width="80" />
      <el-table-column prop="sort" label="排序" width="80" />
      <el-table-column label="操作" width="240" fixed="right">
        <template #default="{ row }">
          <el-button size="small" plain @click="openCreate(row)">加子级</el-button>
          <el-button size="small" @click="openEdit(row)">编辑</el-button>
          <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>
    <el-empty v-if="!loading && !treeData.length" description="暂无分类，先创建根分类" />

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
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; }
.w100 { width: 100%; }
.hint { margin-left: 10px; font-size: 12px; color: var(--el-text-color-secondary); }
</style>
