<script setup>
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { practiceApi } from '../../api'
import { datetime } from '../../utils'
import QuestionCard from '../../components/QuestionCard.vue'
import PaginationBar from '../../components/PaginationBar.vue'

const loading = ref(false)
const tab = ref('wrong') // wrong | fav
const mastered = ref('0') // 0 未掌握 / 1 已掌握 / -1 全部
const items = ref([])
const total = ref(0)
const query = reactive({ page: 1, size: 10 })

async function load() {
  loading.value = true
  try {
    const r =
      tab.value === 'wrong'
        ? await practiceApi.wrongList({ mastered: Number(mastered.value), page: query.page, size: query.size })
        : await practiceApi.favQuestions({ page: query.page, size: query.size })
    items.value = r.items
    total.value = r.total
  } finally {
    loading.value = false
  }
}

function reload() {
  query.page = 1
  load()
}

async function master(row) {
  await practiceApi.masterWrong(row.id)
  ElMessage.success('已标记掌握')
  load()
}

// 收藏 tab 里取消收藏：toggle 后刷新
async function unfav(row) {
  await practiceApi.toggleFavQuestion(row.question.id)
  load()
}

onMounted(load)
</script>

<template>
  <div>
    <el-tabs v-model="tab" @tab-change="reload">
      <el-tab-pane label="错题本" name="wrong" />
      <el-tab-pane label="收藏的题目" name="fav" />
    </el-tabs>

    <div v-if="tab === 'wrong'" class="toolbar">
      <el-radio-group v-model="mastered" @change="reload">
        <el-radio-button value="0">未掌握</el-radio-button>
        <el-radio-button value="1">已掌握</el-radio-button>
        <el-radio-button value="-1">全部</el-radio-button>
      </el-radio-group>
    </div>

    <div v-loading="loading">
      <el-card v-for="(row, i) in items" :key="row.id" class="item" shadow="never">
        <QuestionCard
          :q="row.question"
          :model-value="''"
          disabled
          show-answer
          :index="(query.page - 1) * query.size + i + 1"
          :show-fav="tab === 'fav'"
          :fav="tab === 'fav'"
          @toggle-fav="unfav(row)"
        />
        <div class="foot">
          <template v-if="tab === 'wrong'">
            <span class="meta">已错 {{ row.wrong_count }} 次 · 最后错误 {{ datetime(row.last_wrong_at) }}</span>
            <el-tag v-if="row.mastered" size="small" type="success">已掌握</el-tag>
            <el-button v-else size="small" type="success" plain @click="master(row)">标记已掌握</el-button>
          </template>
          <span v-else class="meta">收藏于 {{ datetime(row.created_at) }}</span>
        </div>
      </el-card>
      <el-empty v-if="!loading && !items.length" :description="tab === 'wrong' ? '暂时没有错题，继续加油！' : '还没有收藏题目'" />
    </div>

    <PaginationBar v-model:page="query.page" :total="total" :size="query.size" @change="load" />
  </div>
</template>

<style scoped>
.toolbar { margin-bottom: 12px; }
.item { margin-bottom: 12px; }
.foot {
  display: flex; justify-content: space-between; align-items: center;
  border-top: 1px solid var(--el-border-color-lighter); padding-top: 8px; margin-top: 4px;
}
.meta { font-size: 12px; color: var(--el-text-color-secondary); }
</style>
