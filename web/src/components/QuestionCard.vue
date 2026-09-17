<script setup>
// 题目卡片：练习（即时反馈）、考试（仅作答）、错题本/收藏（直接展示答案解析）三场景复用。
// answer 统一为字符串：单选 "A"、多选 "AB"（升序）、判断 "T"/"F"、填空为原文。
import { computed } from 'vue'
import RichText from './RichText.vue'

const props = defineProps({
  q: { type: Object, required: true }, // {id,type,stem,options}
  modelValue: { type: String, default: '' },
  disabled: { type: Boolean, default: false },
  index: { type: Number, default: 0 },
  score: { type: Number, default: 0 },
  // 练习提交后的反馈 {correct, answer, explanation}；null = 未提交
  feedback: { type: Object, default: null },
  showAnswer: { type: Boolean, default: false }, // 错题本/收藏：直接带答案
  fav: { type: Boolean, default: false },
  showFav: { type: Boolean, default: false },
})
const emit = defineEmits(['update:modelValue', 'toggle-fav'])

const letters = computed(() => (props.q.options || []).map((_, i) => String.fromCharCode(65 + i)))
const isFill = computed(() => props.q.type === 'fill')
const isMulti = computed(() => props.q.type === 'multi')
const answered = computed(() => !!props.feedback || props.showAnswer)

const multiSel = computed({
  get: () => (props.modelValue ? props.modelValue.split('') : []),
  set: (arr) => emit('update:modelValue', [...arr].sort().join('')),
})

function pick(v) {
  emit('update:modelValue', v)
}
</script>

<template>
  <div class="qc">
    <div class="stem">
      <span v-if="index" class="idx">{{ index }}.</span>
      <el-tag v-if="q.type" size="small" class="type-tag" type="info">
        {{ { single: '单选', multi: '多选', judge: '判断', fill: '填空' }[q.type] || q.type }}
      </el-tag>
      <span v-if="score" class="score">{{ score }} 分</span>
      <RichText :text="q.stem" />
    </div>

    <div class="body">
      <el-input
        v-if="isFill"
        :model-value="modelValue"
        :disabled="disabled && !answered"
        :readonly="answered"
        placeholder="请输入答案"
        @update:model-value="pick"
      />
      <el-radio-group
        v-else-if="!isMulti"
        :model-value="modelValue"
        :disabled="disabled && !answered"
        @update:model-value="pick"
      >
        <template v-if="q.type === 'judge'">
          <el-radio value="T">正确</el-radio>
          <el-radio value="F">错误</el-radio>
        </template>
        <el-radio v-else v-for="(opt, i) in q.options" :key="i" :value="letters[i]">
          {{ letters[i] }}. <RichText :text="opt" />
        </el-radio>
      </el-radio-group>
      <el-checkbox-group
        v-else
        :model-value="multiSel"
        :disabled="disabled && !answered"
        @update:model-value="(v) => (multiSel = v)"
      >
        <el-checkbox v-for="(opt, i) in q.options" :key="i" :value="letters[i]">
          {{ letters[i] }}. <RichText :text="opt" />
        </el-checkbox>
      </el-checkbox-group>
    </div>

    <!-- 反馈区：练习判分结果 / 错题本直接展示 -->
    <div v-if="answered" class="fb">
      <el-alert
        v-if="feedback && !showAnswer"
        :type="feedback.correct ? 'success' : 'error'"
        :closable="false"
        show-icon
        :title="feedback.correct ? '回答正确' : `回答错误，正确答案：${feedback.answer}`"
      />
      <div v-else class="ans-line">
        正确答案：<b>{{ showAnswer ? q.answer : feedback.answer }}</b>
      </div>
      <div v-if="(showAnswer ? q.explanation : feedback.explanation)" class="expl">
        解析：<RichText :text="showAnswer ? q.explanation : feedback.explanation" />
      </div>
    </div>

    <div v-if="showFav" class="ops">
      <el-button size="small" :type="fav ? 'warning' : 'default'" text bg @click="emit('toggle-fav')">
        <el-icon><Star /></el-icon>{{ fav ? '已收藏' : '收藏本题' }}
      </el-button>
    </div>
  </div>
</template>

<style scoped>
.qc { padding: 8px 4px; }
.stem { font-size: 15px; line-height: 1.7; margin-bottom: 10px; }
.idx { color: var(--el-color-primary); font-weight: 600; margin-right: 4px; }
.type-tag { margin-right: 6px; }
.score { color: var(--el-color-warning); font-size: 13px; margin-right: 6px; }
.body :deep(.el-radio) { display: block; margin-bottom: 6px; height: auto; white-space: normal; }
.body :deep(.el-checkbox) { display: block; margin-bottom: 6px; height: auto; white-space: normal; }
.fb { margin-top: 10px; }
.ans-line { font-size: 14px; margin-bottom: 4px; }
.expl { font-size: 13px; color: var(--el-text-color-secondary); background: var(--el-fill-color-light); padding: 8px 10px; border-radius: 4px; }
.ops { margin-top: 8px; }
</style>
