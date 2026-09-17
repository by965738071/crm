<script setup>
import { nextTick, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '../../api'
import { datetime } from '../../utils'
import PaginationBar from '../../components/PaginationBar.vue'

const loading = ref(false)
const tableRef = ref(null)
const items = ref([])
const total = ref(0)
const query = reactive({ status: '', keyword: '', page: 1, size: 20 })

async function load() {
  loading.value = true
  try {
    const r = await adminApi.announcements({
      status: query.status || undefined,
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

const statusMap = {
  draft: { label: '草稿', type: 'info' },
  published: { label: '已发布', type: 'success' },
}

// ---- 新建 / 编辑弹窗 ----
const dlgVisible = ref(false)
const saving = ref(false)
const editingId = ref(0)
const form = reactive({ title: '', content: '', status: 'draft' })

function openCreate() {
  editingId.value = 0
  Object.assign(form, { title: '', content: '', status: 'draft' })
  dlgVisible.value = true
}

function openEdit(row) {
  editingId.value = row.id
  Object.assign(form, { title: row.title, content: row.content, status: row.status })
  dlgVisible.value = true
}

async function submit() {
  const title = form.title.trim()
  if (!title) {
    ElMessage.warning('请输入标题')
    return
  }
  saving.value = true
  try {
    if (editingId.value) {
      // 编辑只改内容；上下架走发布/下架按钮
      await adminApi.updateAnnouncement(editingId.value, { title, content: form.content })
    } else {
      await adminApi.createAnnouncement({ title, content: form.content, status: form.status })
    }
    ElMessage.success('已保存')
    dlgVisible.value = false
    await load()
  } catch {} finally {
    saving.value = false
  }
}

async function togglePublish(row) {
  const publish = row.status !== 'published'
  const ok = await ElMessageBox.confirm(
    publish ? `确定发布公告「${row.title}」吗？发布后学员端可见。` : `确定下架公告「${row.title}」吗？`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    if (publish) await adminApi.publishAnnouncement(row.id)
    else await adminApi.unpublishAnnouncement(row.id)
    ElMessage.success(publish ? '已发布' : '已下架')
    await load()
  } catch {}
}

async function remove(row) {
  const ok = await ElMessageBox.confirm(`确定删除公告「${row.title}」吗？`, '提示', { type: 'warning' })
    .then(() => true)
    .catch(() => false)
  if (!ok) return
  try {
    await adminApi.deleteAnnouncement(row.id)
    ElMessage.success('已删除')
    await load()
  } catch {}
}

onMounted(load)
</script>

<template>
  <div class="page-list">
    <div class="toolbar">
      <el-select v-model="query.status" class="w130" placeholder="状态" @change="search">
        <el-option label="全部状态" value="" />
        <el-option label="草稿" value="draft" />
        <el-option label="已发布" value="published" />
      </el-select>
      <el-input v-model="query.keyword" class="w200" placeholder="标题/内容关键词" clearable
        @keyup.enter="search" @clear="search">
        <template #prefix><el-icon><Search /></el-icon></template>
      </el-input>
      <el-button type="primary" @click="search">查询</el-button>
      <el-button class="create-btn" type="primary" @click="openCreate">新建公告</el-button>
    </div>

    <div class="table-wrap">
    <el-table ref="tableRef" v-loading="loading" :data="items" stripe height="100%">
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column prop="title" label="标题" min-width="220" show-overflow-tooltip />
      <el-table-column prop="content" label="内容" min-width="260" show-overflow-tooltip />
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag size="small" :type="statusMap[row.status]?.type || 'info'">
            {{ statusMap[row.status]?.label || row.status }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="发布时间" width="150">
        <template #default="{ row }">{{ datetime(row.published_at) }}</template>
      </el-table-column>
      <el-table-column label="创建时间" width="150">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="250" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openEdit(row)">编辑</el-button>
          <el-button size="small" :type="row.status === 'published' ? 'warning' : 'success'" plain
            @click="togglePublish(row)">
            {{ row.status === 'published' ? '下架' : '发布' }}
          </el-button>
          <el-button size="small" type="danger" plain @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <el-empty description="暂无公告" />
      </template>
    </el-table>
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="onPage" />

    <el-dialog v-model="dlgVisible" :title="editingId ? '编辑公告' : '新建公告'" width="640">
      <el-form label-width="70px">
        <el-form-item label="标题" required>
          <el-input v-model="form.title" :maxlength="128" show-word-limit />
        </el-form-item>
        <el-form-item label="内容">
          <el-input v-model="form.content" type="textarea" :rows="8" :maxlength="20000" show-word-limit />
        </el-form-item>
        <el-form-item v-if="!editingId" label="状态">
          <el-radio-group v-model="form.status">
            <el-radio-button value="draft">存草稿</el-radio-button>
            <el-radio-button value="published">直接发布</el-radio-button>
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
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; flex: none; }
.w130 { width: 130px; }
.w200 { width: 200px; }
.create-btn { margin-left: auto; }
.table-wrap { flex: 1; min-height: 0; }
</style>
