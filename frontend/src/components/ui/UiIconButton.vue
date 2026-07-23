<script setup lang="ts">
withDefaults(defineProps<{
  label: string
  variant?: 'secondary' | 'danger' | 'ghost'
  type?: 'button' | 'submit' | 'reset'
  disabled?: boolean
}>(), {
  variant: 'secondary',
  type: 'button',
  disabled: false,
})
</script>

<template>
  <button
    class="ui-icon-button"
    :class="`ui-icon-button-${variant}`"
    :type="type"
    :disabled="disabled"
    :aria-label="label"
    :title="label"
  >
    <slot></slot>
  </button>
</template>
