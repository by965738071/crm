<script setup>
import { onMounted, reactive, ref } from 'vue'
import { orderApi } from '../../api'
import { datetime } from '../../utils'

const loading = ref(false)
const items = ref([])
const total = ref(0)
const query = reactive({ status: '', page: 1, size: 15 })

const statusMap = {
  pending: { label: '待支付', type: 'warning' },
  paid: { label: '已支付', type: 'success' },
  cancelled: { label: '已取消', type: 'info' },
}

async function load() {
  loading.value = true
  try {
    const r = await orderApi.myOrders({
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
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <el-table-column prop="order_no" label="订单号" width="220" />
      <el-table-column prop="course_title" label="课程" min-width="200" show-overflow-tooltip />
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
      <el-table-column label="下单时间" width="150">
        <template #default="{ row }">{{ datetime(row.created_at) }}</template>
      </el-table-column>
      <el-table-column label="支付时间" width="150">
        <template #default="{ row }">{{ datetime(row.paid_at) }}</template>
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
  </div>
</template>

<style scoped>
.toolbar { margin-bottom: 14px; }
.amount { color: var(--el-color-danger); font-weight: 600; }
.pager { margin-top: 12px; justify-content: center; }
</style>
