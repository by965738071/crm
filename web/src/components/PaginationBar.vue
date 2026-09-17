<script setup>
defineOptions({ name: 'PaginationBar' })

const props = defineProps({
  // 列表总条数（后端返回的 total）
  total: { type: Number, required: true },
  // v-model:page 双向绑定当前页
  page: { type: Number, default: 1 },
  // 每页条数
  size: { type: Number, default: 20 },
})

const emit = defineEmits(['update:page', 'change'])

function onChange(p) {
  emit('update:page', p)
  emit('change', p)
}
</script>

<template>
  <el-pagination
    class="pager"
    layout="prev, pager, next, total"
    :total="total"
    :page-size="size"
    :current-page="page"
    @current-change="onChange"
  />
</template>

<style scoped>
.pager {
  width: 100%;
  margin-top: 12px;
  justify-content: center;
  flex: none;
}
</style>