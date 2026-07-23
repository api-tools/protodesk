import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import UiButton from './UiButton.vue'
import UiIconButton from './UiIconButton.vue'

describe('shared UI buttons', () => {
  it('renders text and variant class for UiButton', () => {
    const wrapper = mount(UiButton, {
      props: {variant: 'primary'},
      slots: {default: 'Save'},
    })

    expect(wrapper.text()).toBe('Save')
    expect(wrapper.classes()).toContain('ui-button')
    expect(wrapper.classes()).toContain('ui-button-primary')
  })

  it('renders accessible icon-only button', () => {
    const wrapper = mount(UiIconButton, {
      props: {label: 'Close'},
      slots: {default: '<span aria-hidden="true">x</span>'},
    })

    expect(wrapper.attributes('aria-label')).toBe('Close')
    expect(wrapper.attributes('title')).toBe('Close')
    expect(wrapper.classes()).toContain('ui-icon-button')
  })
})
