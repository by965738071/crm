<script setup>
import { computed, nextTick, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi, categoryApi } from '../../api'
import { fileSize, datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const loading = ref(false)
const tableRef = ref(null)
const items = ref([])
const total = ref(0)
// category_id：null = 全部；include_sub：选中分类时是否连子分类一起看
const query = reactive({ category_id: null, include_sub: true, type: '', keyword: '', page: 1, size: 20 })

const treeProps = { label: 'name', value: 'id', children: 'children' }
const treeData = ref([])
const catMap = ref({})

// ---- 左侧分类导航 ----
const treeRef = ref(null)
const counts = ref({}) // category_id -> 资料数（0 = 未分类）

// “全部资料”伪根节点（id=0），真实分类挂在它下面
const navTree = computed(() => [{ id: 0, name: '全部资料', children: treeData.value }])
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
    const r = await adminApi.resourceStats()
    const m = {}
    for (const row of (r && r.items) || []) m[row.category_id] = row.count
    counts.value = m
  } catch {}
}

async function load() {
  loading.value = true
  try {
    const r = await adminApi.resources({
      category_id: query.category_id || undefined,
      sub: query.category_id && query.include_sub ? 1 : undefined,
      type: query.type || undefined,
      keyword: query.keyword || undefined,
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

const typeMap = {
  video: { label: '视频', type: 'primary' },
  audio: { label: '音频', type: 'primary' },
  pdf: { label: 'PDF', type: 'danger' },
  doc: { label: '文档', type: 'warning' },
  image: { label: '图片', type: 'success' },
  markdown: { label: 'Markdown', type: 'success' },
}
const typeOptions = Object.keys(typeMap).map((k) => ({ value: k, label: typeMap[k].label }))

function downloadUrl(row) {
  return `/api/resources/${row.id}/download`
}

function catLabel(id) {
  return (id && catMap.value[id]) || '未分类'
}

// ---- 上传弹窗 ----
// 上传走 multipart：file + name + category_id（必选） + is_public（'1'/'0'），见 handlers/resources.zig upload
const upVisible = ref(false)
const uploading = ref(false)
const fileInput = ref(null)
const pickedName = ref('')
const upForm = reactive({ name: '', category_id: null, is_public: 1 })
let pickedFile = null

function openUpload() {
  pickedFile = null
  pickedName.value = ''
  Object.assign(upForm, { name: '', category_id: query.category_id || null, is_public: 1 })
  upVisible.value = true
}

function onPickFile(e) {
  const f = e.target.files && e.target.files[0]
  if (!f) return
  pickedFile = f
  pickedName.value = f.name
  // 资料名默认用文件名（去扩展名），可改
  if (!upForm.name) upForm.name = f.name.replace(/\.[^.]+$/, '')
}

async function submitUpload() {
  if (!pickedFile) {
    ElMessage.warning('请选择文件')
    return
  }
  if (!upForm.name.trim()) {
    ElMessage.warning('请输入资料名')
    return
  }
  if (!upForm.category_id) {
    ElMessage.warning('请选择资料分类')
    return
  }
  const fd = new FormData()
  fd.append('file', pickedFile)
  fd.append('name', upForm.name.trim())
  fd.append('category_id', String(upForm.category_id))
  fd.append('is_public', upForm.is_public ? '1' : '0')
  uploading.value = true
  try {
    await adminApi.uploadResource(fd)
    ElMessage.success('上传成功')
    upVisible.value = false
    await Promise.all([load(), loadStats()])
  } catch {} finally {
    uploading.value = false
  }
}

// ---- 编辑弹窗（仅 category_id/name/rtype/is_public 生效） ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({ category_id: null, name: '', rtype: 'doc', is_public: 1 })

function openEdit(row) {
  editingId.value = row.id
  Object.assign(form, {
    category_id: row.category_id || null,
    name: row.name,
    rtype: row.rtype,
    is_public: row.is_public,
  })
  dlgVisible.value = true
}

async function submit() {
  if (!form.name.trim()) {
    ElMessage.warning('请输入资料名')
    return
  }
  saving.value = true
  try {
    await adminApi.updateResource(editingId.value, {
      category_id: form.category_id || 0,
      name: form.name.trim(),
      rtype: form.rtype,
      is_public: form.is_public ? 1 : 0,
    })
    ElMessage.success('已保存')
    dlgVisible.value = false
    await Promise.all([load(), loadStats()])
  } catch {} finally {
    saving.value = false
  }
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(`确定删除资料「${row.name}」吗？`, '提示', { type: 'warning' })
    .then(() => true)
    .catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteResource(row.id)
    ElMessage.success('已删除')
    await Promise.all([load(), loadStats()])
  } catch {}
}

onMounted(async () => {
  await Promise.all([loadCats(), loadStats()])
  await load()
})
</script>
<template>
  <div class="res-layout">
    <el-card class="cat-panel" shadow="never">
      <template #header><span class="cat-title">资料分类</span></template>
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
        <el-select v-model="query.type" class="w130" placeholder="类型" @change="search">
          <el-option label="全部类型" value="" />
          <el-option v-for="t in typeOptions" :key="t.value" :label="t.label" :value="t.value" />
        </el-select>
        <el-input v-model="query.keyword" class="w200" placeholder="名称关键词" clearable
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
        <el-button class="create-btn" type="primary" @click="openUpload">上传资料</el-button>
      </div>

      <div class="table-box">
        <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
          <el-table-column prop="id" label="ID" width="70" />
          <el-table-column prop="name" label="资料名" min-width="180" show-overflow-tooltip />
          <el-table-column label="分类" width="150" show-overflow-tooltip>
            <template #default="{ row }">
              <el-tag size="small" :type="row.category_id ? 'info' : 'warning'" effect="plain">
                {{ catLabel(row.category_id) }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="orig_name" label="原文件名" min-width="160" show-overflow-tooltip />
          <el-table-column label="类型" width="100">
            <template #default="{ row }">
              <el-tag size="small" :type="typeMap[row.rtype]?.type || 'info'">
                {{ typeMap[row.rtype]?.label || row.rtype }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column label="大小" width="100">
            <template #default="{ row }">{{ fileSize(row.size) }}</template>
          </el-table-column>
          <el-table-column label="可见性" width="90">
            <template #default="{ row }">
              <el-tag size="small" :type="row.is_public ? 'success' : 'info'">
                {{ row.is_public ? '公开' : '私密' }}
              </el-tag>
            </template>
          </el-table-column>
          <el-table-column prop="uploader_id" label="上传人" width="80" />
          <el-table-column label="上传时间" width="150">
            <template #default="{ row }">{{ datetime(row.created_at) }}</template>
          </el-table-column>
          <el-table-column label="操作" width="200" fixed="right">
            <template #default="{ row }">
              <el-link type="primary" :href="downloadUrl(row)" target="_blank" class="dl-link">下载</el-link>
              <el-button size="small" @click="openEdit(row)">编辑</el-button>
              <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
            </template>
          </el-table-column>
          <template #empty>
            <el-empty :description="query.category_id ? `「${currentCatName()}」下暂无资料` : '暂无资料'" />
          </template>
        </el-table>
      </div>

      <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />
    </div>

    <el-dialog v-model="upVisible" title="上传资料" width="520" :close-on-click-modal="false">
      <el-form label-width="90px">
        <el-form-item label="文件" required>
          <input ref="fileInput" type="file" class="file-input" @change="onPickFile" />
          <div v-if="pickedName" class="picked">已选：{{ pickedName }}（{{ fileSize(pickedFile ? pickedFile.size : 0) }}）</div>
        </el-form-item>
        <el-form-item label="资料名" required>
          <el-input v-model="upForm.name" :maxlength="200" placeholder="展示名称，默认用文件名" />
        </el-form-item>
        <el-form-item label="分类" required>
          <el-tree-select v-model="upForm.category_id" :data="treeData" :props="treeProps" check-strictly
            clearable placeholder="必选，可选父级或子分类" class="w100" />
        </el-form-item>
        <el-form-item label="公开">
          <el-switch v-model="upForm.is_public" :active-value="1" :inactive-value="0" />
          <span class="hint">公开 = 游客可下载；私密需登录</span>
        </el-form-item>
      </el-form>
      <p class="hint block">单文件上限 200MB；分类数据来自「分类管理」。</p>
      <template #footer>
        <el-button @click="upVisible = false">取消</el-button>
        <el-button type="primary" :loading="uploading" @click="submitUpload">上传</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="dlgVisible" title="编辑资料" width="520">
      <el-form label-width="90px">
        <el-form-item label="资料名" required>
          <el-input v-model="form.name" :maxlength="200" />
        </el-form-item>
        <el-form-item label="分类">
          <el-tree-select v-model="form.category_id" :data="treeData" :props="treeProps" check-strictly
            clearable placeholder="可留空（未分类）" class="w100" />
        </el-form-item>
        <el-form-item label="类型">
          <el-select v-model="form.rtype" class="w180">
            <el-option v-for="t in typeOptions" :key="t.value" :label="t.label" :value="t.value" />
          </el-select>
        </el-form-item>
        <el-form-item label="公开">
          <el-switch v-model="form.is_public" :active-value="1" :inactive-value="0" />
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
.res-layout { display: flex; gap: 14px; align-items: stretch; flex: 1; min-height: 0; overflow: hidden; }
.cat-panel { width: 250px; flex: none; display: flex; flex-direction: column; }
.cat-panel :deep(.el-card__body) { padding: 8px 6px; flex: 1; min-height: 0; overflow: auto; }
.cat-title { font-weight: 600; }
.tree-node { display: flex; align-items: center; justify-content: space-between; width: 100%; padding-right: 8px; }
.tree-cnt { margin-left: 8px; font-size: 12px; color: var(--el-text-color-secondary); }
.main-panel { flex: 1; min-width: 0; display: flex; flex-direction: column; overflow: hidden; }
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; align-items: center; flex: none; }
.w130 { width: 130px; }
.w200 { width: 200px; }
.w100 { width: 100%; }
.w180 { width: 180px; }
.create-btn { margin-left: auto; }
.sub-switch { display: inline-flex; align-items: center; gap: 4px; }
.file-input { width: 100%; }
.picked { margin-top: 6px; font-size: 12px; color: var(--el-text-color-secondary); }
.hint { font-size: 12px; color: var(--el-text-color-secondary); }
.hint.block { margin: 4px 0 0; }
.dl-link { margin-right: 12px; }
.table-box { flex: 1; min-height: 0; }
</style>
