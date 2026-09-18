<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'
import { datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

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
const counts = ref({}) // category_id -> 试卷数（0 = 未分类）

// “全部试卷”伪根节点（id=0），真实分类挂在它下面
const navTree = computed(() => [{ id: 0, name: '全部试卷', children: catOptions.value }])
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
    const r = await adminApi.examStats()
    const m = {}
    for (const row of (r && r.items) || []) m[row.category_id] = row.count
    counts.value = m
  } catch {}
}

async function load() {
  loading.value = true
  try {
    const cat = query.category_id || curProject.value?.root_category_id
    const r = await adminApi.exams({
      keyword: query.keyword || undefined,
      status: query.status || undefined,
      category_id: cat || undefined,
      sub: cat && (!query.category_id || query.include_sub) ? 1 : undefined,
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
  published: { label: '已发布', type: 'success' },
}

const ruleTypes = [
  { value: '', label: '任意题型' },
  { value: 'single', label: '单选' },
  { value: 'multi', label: '多选' },
  { value: 'judge', label: '判断' },
]

// ---- 编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({
  category_id: null,
  title: '',
  duration_min: 60,
  total_score: 100,
  pass_score: 60,
  status: 'draft',
})
const rules = ref([])

// Σ(count×score_each) 与总分一致才允许提交（与后端 validateExam 硬校验对齐）
const sumScore = computed(() => rules.value.reduce((s, r) => s + (r.count || 0) * (r.score_each || 0), 0))
const sumCount = computed(() => rules.value.reduce((s, r) => s + (r.count || 0), 0))
const scoreOk = computed(
  () => rules.value.length >= 1 && rules.value.length <= 20 && sumScore.value === form.total_score && sumCount.value <= 100,
)

function emptyRule() {
  return { type: '', category_id: null, count: 10, score_each: 5 }
}

function openCreate() {
  editingId.value = 0
  // 主分类默认带上左侧当前选中的分类（伪根“全部试卷”不预填）
  Object.assign(form, { category_id: query.category_id || null, title: '', duration_min: 60, total_score: 100, pass_score: 60, status: 'draft' })
  rules.value = [emptyRule()]
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  Object.assign(form, {
    category_id: row.category_id || null,
    title: row.title,
    duration_min: row.duration_min,
    total_score: row.total_score,
    pass_score: row.pass_score,
    status: row.status,
  })
  rules.value = (row.rules || []).map((r) => ({ ...r }))
  dlgVisible.value = true
}

function addRule() {
  if (rules.value.length >= 20) return
  rules.value.push(emptyRule())
}

function removeRule(i) {
  rules.value.splice(i, 1)
}

async function submit() {
  const title = form.title.trim()
  if (!title) {
    ElMessage.warning('请输入试卷标题')
    return
  }
  if (!form.category_id) {
    ElMessage.warning('请选择主分类')
    return
  }
  if (rules.value.length < 1) {
    ElMessage.warning('至少需要 1 条抽题规则')
    return
  }
  if (rules.value.some((r) => !r.category_id || r.count < 1 || r.score_each < 1)) {
    ElMessage.warning('每条规则的分类、题数、每题分值都必须填写')
    return
  }
  if (sumCount.value > 100) {
    ElMessage.warning('总题数不能超过 100')
    return
  }
  if (sumScore.value !== form.total_score) {
    ElMessage.warning(`规则分值合计 ${sumScore.value} ≠ 总分 ${form.total_score}，请调整`)
    return
  }
  if (form.pass_score < 0 || form.pass_score > form.total_score) {
    ElMessage.warning('及格分需在 0 与总分之间')
    return
  }

  const payload = {
    category_id: form.category_id,
    title,
    duration_min: form.duration_min,
    total_score: form.total_score,
    pass_score: form.pass_score,
    status: form.status,
    rules: rules.value.map((r) => ({
      type: r.type || '',
      category_id: r.category_id,
      count: r.count,
      score_each: r.score_each,
    })),
  }
  saving.value = true
  try {
    if (editingId.value) await adminApi.updateExam(editingId.value, payload)
    else await adminApi.createExam(payload)
    ElMessage.success('已保存')
    dlgVisible.value = false
    await Promise.all([load(), loadStats()])
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(
    `确定删除试卷「${row.title}」吗？学员历史成绩仍可查看。`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteExam(row.id)
    ElMessage.success('已删除')
    await Promise.all([load(), loadStats()])
  } catch {}
}

onMounted(async () => {
  await Promise.all([loadCats(), loadStats(), adminApi.projects().then((r) => (projects.value = r || []))])
  await load()
})
</script>
<template>
  <div class="exam-layout">
    <el-card class="cat-panel" shadow="never">
      <template #header><span class="cat-title">试卷分类</span></template>
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
          <el-option label="已发布" value="published" />
        </el-select>
        <el-input v-model="query.keyword" class="w200" placeholder="试卷标题" clearable
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
        <el-button class="create-btn" type="primary" @click="openCreate">新建试卷</el-button>
      </div>

      <div class="table-box">
        <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
          <el-table-column prop="id" label="ID" width="70" />
          <el-table-column prop="title" label="标题" min-width="220" show-overflow-tooltip />
          <el-table-column label="主分类" width="130" show-overflow-tooltip>
            <template #default="{ row }">{{ catMap[row.category_id] || '-' }}</template>
          </el-table-column>
          <el-table-column label="时长" width="90">
            <template #default="{ row }">{{ row.duration_min }} 分钟</template>
          </el-table-column>
          <el-table-column prop="total_score" label="总分" width="70" />
          <el-table-column prop="pass_score" label="及格分" width="80" />
          <el-table-column prop="question_count" label="题数" width="70" />
          <el-table-column label="状态" width="90">
            <template #default="{ row }">
              <el-tag size="small" :type="statusMap[row.status]?.type || 'info'">
                {{ statusMap[row.status]?.label || row.status }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column label="创建时间" width="150">
            <template #default="{ row }">{{ datetime(row.created_at) }}</template>
          </el-table-column>
          <el-table-column label="操作" width="150" fixed="right">
            <template #default="{ row }">
              <el-button size="small" @click="openEdit(row)">编辑</el-button>
              <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
            </template>
          </el-table-column>
          <template #empty>
            <el-empty :description="query.category_id ? `「${currentCatName()}」下暂无试卷` : '暂无试卷'" />
          </template>
        </el-table>
      </div>

      <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />
    </div>

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑试卷' : '新建试卷'" width="760">
      <el-form label-width="90px">
        <el-form-item label="主分类" required>
          <el-tree-select v-model="form.category_id" :data="catOptions" :props="treeProps" check-strictly
            placeholder="选择分类" class="w240" />
        </el-form-item>
        <el-form-item label="标题" required>
          <el-input v-model="form.title" :maxlength="128" show-word-limit />
        </el-form-item>
        <el-form-item label="时长（分）">
          <el-input-number v-model="form.duration_min" :min="1" :max="300" controls-position="right" />
        </el-form-item>
        <el-form-item label="总分">
          <el-input-number v-model="form.total_score" :min="1" :max="10000" :step="10" controls-position="right" />
        </el-form-item>
        <el-form-item label="及格分">
          <el-input-number v-model="form.pass_score" :min="0" :max="10000" controls-position="right" />
        </el-form-item>
        <el-form-item label="状态">
          <el-select v-model="form.status" class="w180">
            <el-option label="草稿" value="draft" />
            <el-option label="已发布" value="published" />
          </el-select>
        </el-form-item>
        <el-form-item label="抽题规则" required>
          <div class="rules">
            <el-alert v-if="!scoreOk" type="error" :closable="false" class="mb8" show-icon
              :title="`分值合计 ${sumScore} / 总分 ${form.total_score}，总题数 ${sumCount}（需 ≤100）：两者必须一致`" />
            <el-alert v-else type="success" :closable="false" class="mb8" show-icon
              :title="`分值合计 ${sumScore} = 总分 ${form.total_score}，共 ${sumCount} 题`" />
            <div v-for="(r, i) in rules" :key="i" class="rule-row">
              <el-select v-model="r.type" class="w110">
                <el-option v-for="t in ruleTypes" :key="t.value" :label="t.label" :value="t.value" />
              </el-select>
              <el-tree-select v-model="r.category_id" :data="catOptions" :props="treeProps" check-strictly
                placeholder="题目分类" class="w180" />
              <el-input-number v-model="r.count" :min="1" :max="100" class="w120"
                controls-position="right" placeholder="题数" />
              <el-input-number v-model="r.score_each" :min="1" :max="100" class="w120"
                controls-position="right" placeholder="每题分" />
              <span class="rule-sum">= {{ (r.count || 0) * (r.score_each || 0) }} 分</span>
              <el-button text type="danger" @click="removeRule(i)">
                <el-icon><Delete /></el-icon>
              </el-button>
            </div>
            <el-button text type="primary" :disabled="rules.length >= 20" @click="addRule">+ 添加规则</el-button>
          </div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dlgVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" :disabled="!scoreOk" @click="submit">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.exam-layout { display: flex; gap: 14px; align-items: stretch; flex: 1; min-height: 0; overflow: hidden; }
.cat-panel { width: 250px; flex: none; display: flex; flex-direction: column; }
.cat-panel :deep(.el-card__body) { padding: 8px 6px; flex: 1; min-height: 0; overflow: auto; }
.cat-title { font-weight: 600; }
.tree-node { display: flex; align-items: center; justify-content: space-between; width: 100%; padding-right: 8px; }
.tree-cnt { margin-left: 8px; font-size: 12px; color: var(--el-text-color-secondary); }
.main-panel { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; align-items: center; flex: none; }
.proj-filter { width: 150px; }
.w110 { width: 110px; }
.w120 { width: 120px; }
.w130 { width: 130px; }
.w180 { width: 180px; }
.w200 { width: 200px; }
.w240 { width: 240px; }
.create-btn { margin-left: auto; }
.sub-switch { display: inline-flex; align-items: center; gap: 4px; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.rules { width: 100%; }
.rule-row { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.rule-sum { font-size: 12px; color: var(--el-text-color-secondary); white-space: nowrap; }
.mb8 { margin-bottom: 8px; }
.table-box { flex: 1; min-height: 0; }
</style>
