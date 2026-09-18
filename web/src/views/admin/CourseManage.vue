<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'
import { money, datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const router = useRouter()

const loading = ref(false)
const tableRef = ref(null)
const items = ref([])
const total = ref(0)
// category_id：null = 全部；include_sub：选中分类时是否连子分类一起看
const query = reactive({ category_id: null, include_sub: true, keyword: '', status: '', page: 1, size: 20 })

const treeProps = { label: 'name', value: 'id', children: 'children' }
const treeData = ref([])
const catMap = ref({})

// ---- 专业筛选 ----
const projects = ref([])
const filterProjectId = ref(0)
const curProject = computed(() => projects.value.find((p) => p.id === filterProjectId.value) || null)
// 选中专业时只取该专业根分类下的子树作为分类选项
const catOptions = computed(() => {
  const p = curProject.value
  if (!p) return treeData.value
  const root = treeData.value.find((n) => n.id === p.root_category_id)
  return root ? root.children || [] : []
})

// ---- 左侧分类导航 ----
const treeRef = ref(null)
const counts = ref({}) // category_id -> 课程数（0 = 未分类）

// “全部课程”伪根节点（id=0），真实分类挂在它下面
const navTree = computed(() => [{ id: 0, name: '全部课程', children: catOptions.value }])
// 默认只展开伪根节点 → 展示一级分类；二级及以下保持折叠
const expandedKeys = [0]
const allTotal = computed(() => Object.values(counts.value).reduce((s, n) => s + n, 0))

function countOf(id) {
  if (id === 0) return allTotal.value
  return counts.value[id] || 0
}

function currentCatName() {
  return query.category_id ? catMap.value[query.category_id] || '' : ''
}

function onCatNode(data) {
  query.category_id = data.id === 0 ? null : data.id
  query.page = 1
  load()
}

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
    await nextTick()
    treeRef.value?.setCurrentKey(query.category_id ?? 0)
  } catch {}
}

async function loadStats() {
  try {
    const r = await adminApi.courseStats()
    const m = {}
    for (const row of (r && r.items) || []) m[row.category_id] = row.count
    counts.value = m
  } catch {}
}

async function load() {
  loading.value = true
  try {
    const cat = query.category_id || curProject.value?.root_category_id
    const r = await adminApi.courses({
      keyword: query.keyword || undefined,
      category_id: cat || undefined,
      sub: cat && (!query.category_id || query.include_sub) ? 1 : undefined,
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

async function onPage(p) {
  query.page = p
  await load()
  await nextTick()
  tableRef.value?.setScrollTop(0)
}

function search() {
  query.page = 1
  load()
}

watch(filterProjectId, async () => {
  query.category_id = null
  query.page = 1
  await nextTick()
  treeRef.value?.setCurrentKey(0)
  await load()
})

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
  // 默认带上左侧当前选中的分类（伪根“全部课程”不预填）
  form.category_id = query.category_id || null
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
    await Promise.all([load(), loadStats()])
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
    await Promise.all([load(), loadStats()])
  } catch {}
}

function goLessons(row) {
  router.push(`/admin/courses/${row.id}/lessons`)
}

onMounted(async () => {
  await Promise.all([loadCats(), loadStats(), adminApi.projects().then((r) => (projects.value = r || []))])
  await load()
})
</script>
<template>
  <div class="course-layout">
    <el-card class="cat-panel" shadow="never">
      <template #header><span class="cat-title">课程分类</span></template>
      <el-tree
        ref="treeRef"
        :data="navTree"
        :props="treeProps"
        node-key="id"
        highlight-current
        :default-expanded-keys="expandedKeys"
        :expand-on-click-node="false"
        @node-click="onCatNode"
      >
        <template #default="{ data }">
          <span class="tree-node">
            <span class="tree-label">{{ data.name }}</span>
            <span class="tree-cnt">{{ countOf(data.id) }}</span>
          </span>
        </template>
      </el-tree>
    </el-card>

    <div class="main-panel">
      <div class="toolbar">
        <el-select v-model="filterProjectId" class="proj-filter" placeholder="全部专业">
          <el-option label="全部专业" :value="0" />
          <el-option v-for="p in projects" :key="p.id" :label="p.name" :value="p.id" />
        </el-select>
        <el-select v-model="query.status" class="w130" placeholder="状态" @change="search">
          <el-option label="全部状态" value="" />
          <el-option label="草稿" value="draft" />
          <el-option label="已上架" value="published" />
        </el-select>
        <el-input v-model="query.keyword" class="w200" placeholder="课程标题" clearable
          @keyup.enter="search" @clear="search">
          <template #prefix><el-icon><Search /></el-icon></template>
        </el-input>
        <el-tooltip content="仅选中分类时生效" :disabled="!query.category_id">
          <span class="sub-switch">
            <el-switch v-model="query.include_sub" :disabled="!query.category_id" size="small" @change="search" />
            <span class="hint">含子分类</span>
          </span>
        </el-tooltip>
        <el-button type="primary" @click="search">查询</el-button>
        <el-button class="create-btn" type="primary" @click="openCreate">新建课程</el-button>
      </div>

      <div class="table-box">
        <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
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
          <template #empty>
            <el-empty :description="query.category_id ? `「${currentCatName()}」下暂无课程` : '暂无课程'" />
          </template>
        </el-table>
      </div>

      <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />
    </div>

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑课程' : '新建课程'" width="640">
      <el-form label-width="90px">
        <el-form-item label="分类" required>
          <el-tree-select v-model="form.category_id" :data="catOptions" :props="treeProps" check-strictly
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
.course-layout { display: flex; gap: 14px; align-items: stretch; flex: 1; min-height: 0; overflow: hidden; }
.cat-panel { width: 250px; flex: none; display: flex; flex-direction: column; }
.cat-panel :deep(.el-card__body) { padding: 8px 6px; flex: 1; min-height: 0; overflow: auto; }
.cat-title { font-weight: 600; }
.tree-node { display: flex; align-items: center; justify-content: space-between; width: 100%; padding-right: 8px; }
.tree-cnt { margin-left: 8px; font-size: 12px; color: var(--el-text-color-secondary); }
.main-panel { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; align-items: center; flex: none; }
.proj-filter { width: 150px; }
.w130 { width: 130px; }
.w200 { width: 200px; }
.w100 { width: 100%; }
.w180 { width: 180px; }
.create-btn { margin-left: auto; }
.sub-switch { display: inline-flex; align-items: center; gap: 4px; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.table-box { flex: 1; min-height: 0; }
</style>
