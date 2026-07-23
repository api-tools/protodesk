<script setup lang="ts">
withDefaults(defineProps<{
  variant?: 'primary' | 'secondary' | 'danger' | 'ghost'
  type?: 'button' | 'submit' | 'reset'
  disabled?: boolean
}>(), {
  variant: 'secondary',
  type: 'button',
  disabled: false,
})
</script>

<template>
  <button class="ui-button" :class="`ui-button-${variant}`" :type="type" :disabled="disabled">
    <slot name="icon"></slot>
    <span v-if="$slots.default" class="ui-button-label">
      <slot></slot>
    </span>
  </button>
</template>
