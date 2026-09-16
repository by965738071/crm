<script setup>
import { onMounted, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'
import { money, datetime } from '../../utils'

const router = useRouter()

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ keyword: '', category_id: null, status: '', page: 1, size: 20 })

const treeProps = { label: 'name', value: 'id', children: 'children' }
const treeData = ref([])
const catMap = ref({})

function flatten(nodes) {
  for (const n of nodes || []) {
    catMap.value[n.id] = n.name
    if (n.children && n.children.length) flatten(n.children)
  }
}

async function loadCats() {
  try {
    const r = await categoryApi.tree()
    treeData.value = r || []
    catMap.value = {}
    flatten(treeData.value)
  } catch {}
}

async function load() {
  loading.value = true
  try {
    const r = await adminApi.courses({
      keyword: query.keyword || undefined,
      category_id: query.category_id || undefined,
      status: query.status || undefined,
      page: query.page,
      size: query.size,
    })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function search() {
  query.page = 1
  load()
}

const statusMap = {
  draft: { label: '草稿', type: 'info' },
  published: { label: '已上架', type: 'success' },
}

// ---- 课程编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({
  category_id: null,
  title: '',
  cover: '',
  summary: '',
  description: '',
  priceYuan: 0,
  is_free: 0,
  status: 'draft',
  sort: 0,
})

function resetForm(row) {
  Object.assign(form, {
    category_id: row ? row.category_id : null,
    title: row ? row.title : '',
    cover: row ? row.cover : '',
    summary: row ? row.summary : '',
    description: row ? row.description : '',
    priceYuan: row ? row.price / 100 : 0,
    is_free: row ? row.is_free : 0,
    status: row ? row.status : 'draft',
    sort: row ? row.sort : 0,
  })
}

function openCreate() {
  editingId.value = 0
  resetForm(null)
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  resetForm(row)
  dlgVisible.value = true
}

async function submit() {
  const title = form.title.trim()
  if (!title) {
    ElMessage.warning('请输入课程标题')
    return
  }
  if (!form.category_id) {
    ElMessage.warning('请选择所属分类')
    return
  }
  const payload = {
    category_id: form.category_id,
    title,
    cover: form.cover.trim(),
    summary: form.summary.trim(),
    description: form.description,
    // 金额以分入库；免费课程强制 0
    price: form.is_free ? 0 : Math.max(0, Math.round((form.priceYuan || 0) * 100)),
    is_free: form.is_free ? 1 : 0,
    status: form.status,
    sort: form.sort || 0,
  }
  saving.value = true
  try {
    if (editingId.value) await adminApi.updateCourse(editingId.value, payload)
    else await adminApi.createCourse(payload)
    ElMessage.success('已保存')
    dlgVisible.value = false
    await load()
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(
    `确定删除课程「${row.title}」吗？其章节与课时将一并软删。`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteCourse(row.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

function goLessons(row) {
  router.push(`/admin/courses/${row.id}/lessons`)
}

onMounted(async () => {
  await loadCats()
  await load()
})
</script>
<template>
  <div>
    <div class="toolbar">
      <el-tree-select v-model="query.category_id" :data="treeData" :props="treeProps" check-strictly
        clearable placeholder="全部分类" class="w180" @change="search" />
      <el-select v-model="query.status" class="w130" placeholder="状态" @change="search">
        <el-option label="全部状态" value="" />
        <el-option label="草稿" value="draft" />
        <el-option label="已上架" value="published" />
      </el-select>
      <el-input v-model="query.keyword" class="w200" placeholder="课程标题" clearable
        @keyup.enter="search" @clear="search">
        <template #prefix><el-icon><Search /></el-icon></template>
      </el-input>
      <el-button type="primary" @click="search">查询</el-button>
      <el-button class="create-btn" type="primary" @click="openCreate">新建课程</el-button>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column prop="title" label="标题" min-width="220" show-overflow-tooltip />
      <el-table-column label="分类" width="140" show-overflow-tooltip>
        <template #default="{ row }">{{ catMap[row.category_id] || '-' }}</template>
      </el-table-column>
      <el-table-column label="价格" width="100">
        <template #default="{ row }">{{ row.is_free ? '免费' : money(row.price) }}</template>
      </el-table-column>
      <el-table-column prop="enroll_count" label="报名" width="80" />
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag size="small" :type="statusMap[row.status]?.type || 'info'">
            {{ statusMap[row.status]?.label || row.status }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="sort" label="排序" width="70" />
      <el-table-column label="创建时间" width="150">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="230" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openEdit(row)">编辑</el-button>
          <el-button size="small" type="primary" plain @click="goLessons(row)">章节课时</el-button>
          <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>
    <el-empty v-if="!loading && !items.length" description="暂无课程" />

    <el-pagination
      v-if="total > query.size"
      class="pager"
      layout="prev, pager, next, total"
      :total="total"
      :page-size="query.size"
      :current-page="query.page"
      @current-change="(p) => { query.page = p; load() }"
    />

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑课程' : '新建课程'" width="640">
      <el-form label-width="90px">
        <el-form-item label="分类" required>
          <el-tree-select v-model="form.category_id" :data="treeData" :props="treeProps" check-strictly
            placeholder="选择分类" class="w100" />
        </el-form-item>
        <el-form-item label="标题" required>
          <el-input v-model="form.title" :maxlength="200" show-word-limit placeholder="课程标题" />
        </el-form-item>
        <el-form-item label="封面 URL">
          <el-input v-model="form.cover" placeholder="选填，图片地址" />
        </el-form-item>
        <el-form-item label="简介">
          <el-input v-model="form.summary" :maxlength="255" show-word-limit placeholder="列表页展示的一句话简介" />
        </el-form-item>
        <el-form-item label="详细介绍">
          <el-input v-model="form.description" type="textarea" :rows="4" placeholder="选填" />
        </el-form-item>
        <el-form-item label="免费">
          <el-switch v-model="form.is_free" :active-value="1" :inactive-value="0" />
        </el-form-item>
        <el-form-item label="价格（元）">
          <el-input-number v-model="form.priceYuan" :min="0" :precision="2" :step="10"
            :disabled="!!form.is_free" />
        </el-form-item>
        <el-form-item label="状态">
          <el-select v-model="form.status" class="w180">
            <el-option label="草稿" value="draft" />
            <el-option label="已上架" value="published" />
          </el-select>
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
.w130 { width: 130px; }
.w180 { width: 180px; }
.w200 { width: 200px; }
.w100 { width: 100%; }
.create-btn { margin-left: auto; }
.hint { margin-left: 10px; font-size: 12px; color: var(--el-text-color-secondary); }
.pager { margin-top: 12px; justify-content: center; }
</style>
