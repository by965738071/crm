<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ keyword: '', type: '', category_id: null, page: 1, size: 20 })

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
    const r = await adminApi.questions({
      keyword: query.keyword || undefined,
      type: query.type || undefined,
      category_id: query.category_id || undefined,
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
    await load()
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
    await load()
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
    await load()
  } catch {} finally {
    impSaving.value = false
  }
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
      <el-button type="primary" @click="search">查询</el-button>
      <el-button class="create-btn" @click="openImport">批量导入</el-button>
      <el-button type="primary" @click="openCreate">新建题目</el-button>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column label="题型" width="80">
        <template #default="{ row }">
          <el-tag size="small" :type="typeMap[row.type]?.type || 'info'">
            {{ typeMap[row.type]?.label || row.type }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="stem" label="题干" min-width="280" show-overflow-tooltip />
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
    </el-table>
    <el-empty v-if="!loading && !items.length" description="暂无题目" />

    <el-pagination
      v-if="total > query.size"
      class="pager"
      layout="prev, pager, next, total"
      :total="total"
      :page-size="query.size"
      :current-page="query.page"
      @current-change="(p) => { query.page = p; load() }"
    />

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
          <el-tree-select v-model="form.category_id" :data="treeData" :props="treeProps" check-strictly
            placeholder="选择分类" class="w240" />
          <span class="lbl">关联课程 ID</span>
          <el-input-number v-model="form.course_id" :min="0" controls-position="right" class="w140" />
          <span class="hint">0 = 不关联</span>
        </el-form-item>
        <el-form-item label="题干" required>
          <el-input v-model="form.stem" type="textarea" :rows="3" :maxlength="4000" show-word-limit />
        </el-form-item>
        <el-form-item v-if="needOptions" label="选项">
          <div class="opts">
            <div v-for="(o, i) in form.options" :key="i" class="opt-row">
              <el-tag size="small" class="opt-letter">{{ letters[i] }}</el-tag>
              <el-input v-model="form.options[i]" :maxlength="500" placeholder="选项内容" />
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
            placeholder="选填，题目解析" />
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
  </div>
</template>

<style scoped>
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; }
.w130 { width: 130px; }
.w140 { width: 140px; }
.w180 { width: 180px; }
.w200 { width: 200px; }
.w120 { width: 120px; }
.w240 { width: 240px; }
.create-btn { margin-left: auto; }
.opts { width: 100%; }
.opt-row { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.opt-letter { width: 34px; justify-content: center; flex: none; }
.lbl { margin: 0 8px 0 16px; font-size: 13px; color: var(--el-text-color-regular); }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.hint.block { margin: 8px 0 0; line-height: 1.6; }
.mb12 { margin-bottom: 12px; }
.pager { margin-top: 12px; justify-content: center; }
</style>
