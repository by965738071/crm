<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'
import PaginationBar from '../../components/PaginationBar.vue'
import RichText from '../../components/RichText.vue'

const loading = ref(false)
const tableRef = ref(null)
const items = ref([])
const total = ref(0)
// category_id：null = 全部；include_sub：选中分类时是否连子分类一起看
const query = reactive({ category_id: null, include_sub: true, keyword: '', type: '', page: 1, size: 20 })

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
const counts = ref({}) // category_id -> 题目数（0 = 未分类）

// “全部题目”伪根节点（id=0），真实分类挂在它下面
const navTree = computed(() => [{ id: 0, name: '全部题目', children: catOptions.value }])
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
    const r = await adminApi.questionStats()
    const m = {}
    for (const row of (r && r.items) || []) m[row.category_id] = row.count
    counts.value = m
  } catch {}
}

async function load() {
  loading.value = true
  try {
    const cat = query.category_id || curProject.value?.root_category_id
    const r = await adminApi.questions({
      keyword: query.keyword || undefined,
      type: query.type || undefined,
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

// ---- 题干/选项/解析插入图片 ----
const imgUploadRef = ref(null)
const imgTarget = ref(null) // 'stem' | 'expl' | 选项下标
const stemInputRef = ref(null)
const explInputRef = ref(null)

function pickImage(target) {
  imgTarget.value = target
  if (imgUploadRef.value) {
    imgUploadRef.value.value = ''
    imgUploadRef.value.click()
  }
}

function insertAtCursor(el, key, snippet) {
  const cur = form[key] || ''
  if (!el) {
    form[key] = cur + snippet
    return
  }
  const s = el.selectionStart ?? cur.length
  const e = el.selectionEnd ?? s
  form[key] = cur.slice(0, s) + snippet + cur.slice(e)
}

async function onPickImage(e) {
  const f = e.target.files && e.target.files[0]
  if (!f) return
  try {
    // 携当前题目分类 id：图片按分类归档到 images/<分类id>/<yyyy-mm>/
    const r = await adminApi.uploadImage(f, form.category_id)
    const snippet = `![图](${r.url})`
    const t = imgTarget.value
    if (t === 'stem') {
      insertAtCursor(stemInputRef.value?.textarea, 'stem', snippet)
    } else if (t === 'expl') {
      insertAtCursor(explInputRef.value?.textarea, 'explanation', snippet)
    } else if (typeof t === 'number') {
      const prev = form.options[t] || ''
      form.options[t] = prev ? `${prev} ${snippet}` : snippet
    }
    ElMessage.success('图片已插入')
  } catch {
    ElMessage.error('图片上传失败，请重试')
  }
}

const typeMap = {
  single: { label: '单选', type: 'primary' },
  multi: { label: '多选', type: 'warning' },
  judge: { label: '判断', type: 'success' },
}

// ---- 编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({
  category_id: null,
  course_id: 0,
  type: 'single',
  stem: '',
  options: ['', ''],
  answerSingle: '',
  answerMulti: [],
  answerJudge: 'T',
  explanation: '',
  difficulty: 2,
})

// 选项字母 A..（最多 12 个，与后端 max_options 对齐）
const letters = computed(() => form.options.map((_, i) => String.fromCharCode(65 + i)))
const needOptions = computed(() => form.type === 'single' || form.type === 'multi')

function onTypeChange() {
  form.answerSingle = ''
  form.answerMulti = []
  form.answerJudge = 'T'
}

function openCreate() {
  editingId.value = 0
  Object.assign(form, {
    category_id: query.category_id || null,
    course_id: 0,
    type: 'single',
    stem: '',
    options: ['', ''],
    answerSingle: '',
    answerMulti: [],
    answerJudge: 'T',
    explanation: '',
    difficulty: 2,
  })
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  const opts = row.options && row.options.length ? [...row.options] : ['', '']
  Object.assign(form, {
    category_id: row.category_id || null,
    course_id: row.course_id || 0,
    type: row.type,
    stem: row.stem,
    options: opts,
    answerSingle: row.type === 'single' ? row.answer : '',
    answerMulti: row.type === 'multi' ? row.answer.split('') : [],
    answerJudge: row.answer === 'F' ? 'F' : 'T',
    explanation: row.explanation || '',
    difficulty: row.difficulty || 2,
  })
  dlgVisible.value = true
}

function addOption() {
  if (form.options.length >= 12) return
  form.options.push('')
}

function removeOption(i) {
  form.options.splice(i, 1)
  // 答案字母可能越界，直接清掉重选
  form.answerSingle = ''
  form.answerMulti = []
}

async function submit() {
  const stem = form.stem.trim()
  if (!stem) {
    ElMessage.warning('请输入题干')
    return
  }
  if (!form.category_id) {
    ElMessage.warning('请选择所属分类')
    return
  }
  let options = []
  let answer = ''
  if (needOptions.value) {
    if (form.options.length < 2) {
      ElMessage.warning('选项至少 2 个')
      return
    }
    if (form.options.some((o) => !o.trim())) {
      ElMessage.warning('选项内容不能为空')
      return
    }
    options = form.options.map((o) => o.trim())
    if (form.type === 'single') {
      if (!form.answerSingle) {
        ElMessage.warning('请选择正确答案')
        return
      }
      answer = form.answerSingle
    } else {
      if (form.answerMulti.length < 2) {
        ElMessage.warning('多选题答案至少 2 个选项')
        return
      }
      answer = [...form.answerMulti].sort().join('')
    }
  } else {
    answer = form.answerJudge
  }

  const payload = {
    category_id: form.category_id,
    course_id: form.course_id || 0,
    type: form.type,
    stem,
    options,
    answer,
    explanation: form.explanation,
    difficulty: form.difficulty || 2,
  }
  saving.value = true
  try {
    if (editingId.value) await adminApi.updateQuestion(editingId.value, payload)
    else await adminApi.createQuestion(payload)
    ElMessage.success('已保存')
    dlgVisible.value = false
    await Promise.all([load(), loadStats()])
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm('确定删除该题目吗？', '提示', { type: 'warning' })
    .then(() => true)
    .catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteQuestion(row.id)
    ElMessage.success('已删除')
    await Promise.all([load(), loadStats()])
  } catch {}
}

// ---- 批量导入 ----
const CSV_HEADER = 'type,category_id,course_id,stem,options,answer,explanation,difficulty'
const impVisible = ref(false)
const impSaving = ref(false)
const impMode = ref('csv')
const impCsv = ref('')
const impJson = ref('')

function openImport() {
  impMode.value = 'csv'
  impCsv.value = `${CSV_HEADER}\n`
  impJson.value = ''
  impVisible.value = true
}

async function submitImport() {
  let payload
  if (impMode.value === 'csv') {
    if (impCsv.value.trim().split('\n').length < 2) {
      ElMessage.warning('CSV 至少需要表头 + 1 行数据')
      return
    }
    payload = { csv: impCsv.value }
  } else {
    let arr
    try {
      arr = JSON.parse(impJson.value)
    } catch {
      ElMessage.warning('JSON 解析失败，请检查格式')
      return
    }
    if (!Array.isArray(arr) || !arr.length) {
      ElMessage.warning('JSON 需为非空题目数组')
      return
    }
    payload = { questions: arr }
  }
  impSaving.value = true
  try {
    const r = await adminApi.importQuestions(payload)
    ElMessage.success(`成功导入 ${r.imported} 道题`)
    impVisible.value = false
    await Promise.all([load(), loadStats()])
  } catch {} finally {
    impSaving.value = false
  }
}

onMounted(async () => {
  await Promise.all([loadCats(), loadStats(), adminApi.projects().then((r) => (projects.value = r || []))])
  await load()
})
</script>
<template>
  <div class="question-layout">
    <el-card class="cat-panel" shadow="never">
      <template #header><span class="cat-title">题目分类</span></template>
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
        <el-select v-model="query.type" class="w130" placeholder="题型" @change="search">
          <el-option label="全部题型" value="" />
          <el-option label="单选" value="single" />
          <el-option label="多选" value="multi" />
          <el-option label="判断" value="judge" />
        </el-select>
        <el-input v-model="query.keyword" class="w200" placeholder="题干关键词" clearable
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
        <el-button class="create-btn" @click="openImport">批量导入</el-button>
        <el-button type="primary" @click="openCreate">新建题目</el-button>
      </div>

      <div class="table-box">
        <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
          <el-table-column prop="id" label="ID" width="70" />
          <el-table-column label="题型" width="80">
            <template #default="{ row }">
              <el-tag size="small" :type="typeMap[row.type]?.type || 'info'">
                {{ typeMap[row.type]?.label || row.type }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column label="题干" min-width="280">
            <template #default="{ row }"><RichText :text="row.stem" class="stem-rich" /></template>
          </el-table-column>
          <el-table-column label="分类" width="130" show-overflow-tooltip>
            <template #default="{ row }">{{ catMap[row.category_id] || '-' }}</template>
          </el-table-column>
          <el-table-column prop="answer" label="答案" width="90" show-overflow-tooltip />
          <el-table-column prop="difficulty" label="难度" width="70" />
          <el-table-column prop="used_count" label="使用" width="70" />
          <el-table-column label="操作" width="150" fixed="right">
            <template #default="{ row }">
              <el-button size="small" @click="openEdit(row)">编辑</el-button>
              <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
            </template>
          </el-table-column>
          <template #empty>
            <el-empty :description="query.category_id ? `「${currentCatName()}」下暂无题目` : '暂无题目'" />
          </template>
        </el-table>
      </div>

      <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />
    </div>

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑题目' : '新建题目'" width="680">
      <el-form label-width="90px">
        <el-form-item label="题型">
          <el-radio-group v-model="form.type" @change="onTypeChange">
            <el-radio-button value="single">单选</el-radio-button>
            <el-radio-button value="multi">多选</el-radio-button>
            <el-radio-button value="judge">判断</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="分类" required>
          <el-tree-select v-model="form.category_id" :data="catOptions" :props="treeProps" check-strictly
            placeholder="选择分类" class="w240" />
          <span class="lbl">关联课程 ID</span>
          <el-input-number v-model="form.course_id" :min="0" controls-position="right" class="w140" />
          <span class="hint">0 = 不关联</span>
        </el-form-item>
        <el-form-item label="题干" required>
          <el-input v-model="form.stem" type="textarea" :rows="3" :maxlength="4000" show-word-limit ref="stemInputRef" />
          <el-button size="small" text type="primary" class="inline-img-btn" @click="pickImage('stem')">
            <el-icon><Picture /></el-icon>插入图片
          </el-button>
          <span class="hint block">支持在题干中插入图片，学员端将渲染成图</span>
          <div v-if="form.stem.includes('![')" class="md-preview">预览：<RichText :text="form.stem" /></div>
        </el-form-item>
        <el-form-item v-if="needOptions" label="选项">
          <div class="opts">
            <div v-for="(o, i) in form.options" :key="i" class="opt-row">
              <el-tag size="small" class="opt-letter">{{ letters[i] }}</el-tag>
              <el-input v-model="form.options[i]" :maxlength="500" placeholder="选项内容" />
              <el-tooltip content="在该选项插入图片" placement="top">
                <el-button text type="primary" class="opt-img-btn" @click="pickImage(i)">
                  <el-icon><Picture /></el-icon>
                </el-button>
              </el-tooltip>
              <el-button text type="danger" :disabled="form.options.length <= 2"
                @click="removeOption(i)">
                <el-icon><Delete /></el-icon>
              </el-button>
            </div>
            <el-button text type="primary" :disabled="form.options.length >= 12" @click="addOption">
              + 添加选项
            </el-button>
          </div>
        </el-form-item>
        <el-form-item label="正确答案" required>
          <el-select v-if="form.type === 'single'" v-model="form.answerSingle" placeholder="选择答案" class="w120">
            <el-option v-for="l in letters" :key="l" :label="l" :value="l" />
          </el-select>
          <el-checkbox-group v-else-if="form.type === 'multi'" v-model="form.answerMulti">
            <el-checkbox v-for="l in letters" :key="l" :value="l">{{ l }}</el-checkbox>
          </el-checkbox-group>
          <el-radio-group v-else v-model="form.answerJudge">
            <el-radio value="T">正确</el-radio>
            <el-radio value="F">错误</el-radio>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="解析">
          <el-input v-model="form.explanation" type="textarea" :rows="2" :maxlength="8000"
            placeholder="选填，题目解析" ref="explInputRef" />
          <el-button size="small" text type="primary" class="inline-img-btn" @click="pickImage('expl')">
            <el-icon><Picture /></el-icon>插入图片
          </el-button>
          <div v-if="form.explanation.includes('![')" class="md-preview">预览：<RichText :text="form.explanation" /></div>
        </el-form-item>
        <el-form-item label="难度">
          <el-input-number v-model="form.difficulty" :min="1" :max="5" controls-position="right" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dlgVisible = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="submit">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="impVisible" title="批量导入题目" width="680">
      <el-radio-group v-model="impMode" class="mb12">
        <el-radio-button value="csv">CSV 文本</el-radio-button>
        <el-radio-button value="json">JSON 数组</el-radio-button>
      </el-radio-group>
      <template v-if="impMode === 'csv'">
        <el-input v-model="impCsv" type="textarea" :rows="10" spellcheck="false" />
        <p class="hint block">
          表头固定为 <code>{{ CSV_HEADER }}</code>；options 用竖线分隔（如 A|B|C|D，判断题留空）；
          多选答案写字母连串（如 ABD）；判断题答案 T/F；course_id、difficulty 留空取默认。
          题干/选项如需图片，先上传再粘贴 <code>![图](/uploads/images/xxx.png)</code> 语法。
        </p>
      </template>
      <template v-else>
        <el-input v-model="impJson" type="textarea" :rows="10" spellcheck="false"
          placeholder='[{"type":"single","category_id":1,"stem":"?","options":["甲","乙"],"answer":"A"}]' />
        <p class="hint block">字段同单题新建；整个 JSON 数组一次提交。</p>
      </template>
      <template #footer>
        <el-button @click="impVisible = false">取消</el-button>
        <el-button type="primary" :loading="impSaving" @click="submitImport">导入</el-button>
      </template>
    </el-dialog>

    <input ref="imgUploadRef" type="file" accept="image/png,image/jpeg,image/gif,image/webp" class="hidden-input" @change="onPickImage" />
  </div>
</template>

<style scoped>
.question-layout { display: flex; gap: 14px; align-items: stretch; flex: 1; min-height: 0; overflow: hidden; }
.cat-panel { width: 250px; flex: none; display: flex; flex-direction: column; }
.cat-panel :deep(.el-card__body) { padding: 8px 6px; flex: 1; min-height: 0; overflow: auto; }
.cat-title { font-weight: 600; }
.tree-node { display: flex; align-items: center; justify-content: space-between; width: 100%; padding-right: 8px; }
.tree-cnt { margin-left: 8px; font-size: 12px; color: var(--el-text-color-secondary); }
.main-panel { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; align-items: center; flex: none; }
.proj-filter { width: 150px; }
.hidden-input { display: none; }
.inline-img-btn { margin-top: 6px; }
/* 列表题干：最多 3 行折叠，图片仍可以「图N」占位 hover 预览 */
.stem-rich {
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.md-preview { margin-top: 4px; font-size: 13px; color: var(--el-text-color-secondary); }
.opt-img-btn { margin: 0; }
.w130 { width: 130px; }
.w140 { width: 140px; }
.w200 { width: 200px; }
.w120 { width: 120px; }
.w240 { width: 240px; }
.create-btn { margin-left: auto; }
.sub-switch { display: inline-flex; align-items: center; gap: 4px; }
.opts { width: 100%; }
.opt-row { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.opt-letter { width: 34px; justify-content: center; flex: none; }
.lbl { margin: 0 8px 0 16px; font-size: 13px; color: var(--el-text-color-regular); }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.hint.block { margin: 8px 0 0; line-height: 1.6; }
.mb12 { margin-bottom: 12px; }
.table-box { flex: 1; min-height: 0; }
</style>
