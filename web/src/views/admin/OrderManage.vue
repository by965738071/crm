<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { adminApi } from '../../api'
import { datetime } from '../../utils'

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ status: '', keyword: '', user_id: 0, page: 1, size: 20 })

const statusMap = {
  pending: { label: '待支付', type: 'warning' },
  paid: { label: '已支付', type: 'success' },
  cancelled: { label: '已取消', type: 'info' },
}

const payMethods = [
  { value: 'alipay', label: '支付宝' },
  { value: 'wechat', label: '微信' },
  { value: 'manual', label: '线下/人工' },
]

async function load() {
  loading.value = true
  try {
    const r = await adminApi.orders({
      status: query.status || undefined,
      keyword: query.keyword || undefined,
      user_id: query.user_id > 0 ? query.user_id : undefined,
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

// 标记已支付
const payVisible = ref(false)
const paySaving = ref(false)
const payForm = reactive({ id: 0, pay_method: 'manual', remark: '' })

function openPay(row) {
  payForm.id = row.id
  payForm.pay_method = 'manual'
  payForm.remark = ''
  payVisible.value = true
}

async function submitPay() {
  paySaving.value = true
  try {
    await adminApi.payOrder(payForm.id, {
      pay_method: payForm.pay_method || 'manual',
      remark: payForm.remark,
    })
    ElMessage.success('已标记支付')
    payVisible.value = false
    await load()
  } catch {} finally {
    paySaving.value = false
  }
}

async function cancelOrder(row) {
  const ok = await ElMessageBox.confirm(
    `确定取消订单「${row.order_no}」吗？`,
    '提示',
    { type: 'warning' },
  ).then(() => true).catch(() => false)
  if (!ok) return
  try {
    await adminApi.cancelOrder(row.id)
    ElMessage.success('已取消')
    await load()
  } catch {}
}

// 代下单
const createVisible = ref(false)
const createSaving = ref(false)
const createForm = reactive({ user_id: null, course_id: null })

function openCreate() {
  createForm.user_id = null
  createForm.course_id = null
  createVisible.value = true
}

async function submitCreate() {
  if (!createForm.user_id || !createForm.course_id) {
    ElMessage.warning('请填写用户 ID 和课程 ID')
    return
  }
  createSaving.value = true
  try {
    await adminApi.createOrder({
      user_id: createForm.user_id,
      course_id: createForm.course_id,
    })
    ElMessage.success('已创建待支付订单')
    createVisible.value = false
    await load()
  } catch {} finally {
    createSaving.value = false
  }
}

onMounted(load)
</script>

<template>
  <div>
    <div class="toolbar">
      <el-radio-group v-model="query.status" @change="search">
        <el-radio-button value="">全部</el-radio-button>
        <el-radio-button value="pending">待支付</el-radio-button>
        <el-radio-button value="paid">已支付</el-radio-button>
        <el-radio-button value="cancelled">已取消</el-radio-button>
      </el-radio-group>
      <el-input
        v-model="query.keyword"
        class="w200"
        placeholder="订单号/课程名"
        clearable
        @keyup.enter="search"
        @clear="search"
      >
        <template #prefix><el-icon><Search /></el-icon></template>
      </el-input>
      <el-input-number
        v-model="query.user_id"
        class="w140"
        :min="0"
        :controls="true"
        controls-position="right"
        placeholder="用户 ID"
      />
      <el-button type="primary" @click="search">查询</el-button>
      <el-button class="create-btn" type="primary" @click="openCreate">代下单</el-button>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="id" label="ID" width="70" />
      <el-table-column prop="order_no" label="订单号" width="210" show-overflow-tooltip />
      <el-table-column label="用户" min-width="160">
        <template #default="{ row }">
          <div>{{ row.nickname || row.username || '-' }} / {{ row.username }}</div>
          <div class="sub-text">用户 ID: {{ row.user_id }}</div>
        </template>
      </el-table-column>
      <el-table-column prop="course_title" label="课程" min-width="180" show-overflow-tooltip />
      <el-table-column label="金额" width="110">
        <template #default="{ row }">
          <span class="amount">¥{{ (row.amount / 100).toFixed(2) }}</span>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="100">
        <template #default="{ row }">
          <el-tag size="small" :type="statusMap[row.status]?.type || 'info'">
            {{ statusMap[row.status]?.label || row.status }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column label="支付方式" width="110">
        <template #default="{ row }">{{ row.pay_method || '-' }}</template>
      </el-table-column>
      <el-table-column prop="remark" label="备注" min-width="140" show-overflow-tooltip />
      <el-table-column label="下单时间" width="150">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="支付时间" width="150">
        <template #default="{ row }">{{ datetime(row.paid_at) }}</template>
      </el-table-column>
      <el-table-column label="操作" width="190" fixed="right">
        <template #default="{ row }">
          <template v-if="row.status === 'pending'">
            <el-button size="small" type="primary" @click="openPay(row)">标记已支付</el-button>
            <el-button size="small" type="danger" plain @click="cancelOrder(row)">取消订单</el-button>
          </template>
        </template>
      </el-table-column>
    </el-table>
    <el-empty v-if="!loading && !items.length" description="暂无订单" />

    <el-pagination
      v-if="total > query.size"
      class="pager"
      layout="prev, pager, next, total"
      :total="total"
      :page-size="query.size"
      :current-page="query.page"
      @current-change="(p) => { query.page = p; load() }"
    />

    <el-dialog v-model="payVisible" title="标记已支付" width="460">
      <el-form label-width="80px">
        <el-form-item label="支付方式">
          <el-select v-model="payForm.pay_method" class="w100" filterable allow-create default-first-option placeholder="请选择或输入">
            <el-option v-for="m in payMethods" :key="m.value" :label="m.label" :value="m.value" />
          </el-select>
        </el-form-item>
        <el-form-item label="备注">
          <el-input v-model="payForm.remark" type="textarea" :rows="3" :maxlength="512" show-word-limit placeholder="选填" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="payVisible = false">取消</el-button>
        <el-button type="primary" :loading="paySaving" @click="submitPay">确定</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="createVisible" title="代下单" width="460">
      <el-form label-width="80px">
        <el-form-item label="用户 ID" required>
          <el-input-number v-model="createForm.user_id" :min="1" controls-position="right" />
        </el-form-item>
        <el-form-item label="课程 ID" required>
          <el-input-number v-model="createForm.course_id" :min="1" controls-position="right" />
        </el-form-item>
      </el-form>
      <p class="hint">仅对已上架付费课程有效；用户未报名才会建单</p>
      <template #footer>
        <el-button @click="createVisible = false">取消</el-button>
        <el-button type="primary" :loading="createSaving" @click="submitCreate">确定</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.toolbar { display: flex; gap: 10px; margin-bottom: 14px; }
.w200 { width: 200px; }
.w140 { width: 140px; }
.w100 { width: 100%; }
.create-btn { margin-left: auto; }
.amount { color: var(--el-color-danger); font-weight: 600; }
.sub-text { font-size: 12px; color: var(--el-text-color-secondary); }
.hint { margin: 4px 0 0; font-size: 12px; color: var(--el-text-color-secondary); }
.pager { margin-top: 12px; justify-content: center; }
</style>
