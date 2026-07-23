import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import BottomStatusPanel from './BottomStatusPanel.vue'

describe('BottomStatusPanel', () => {
  it('highlights invoke result and duration separately', () => {
    const wrapper = mount(BottomStatusPanel, {
      props: {
        status: {
          level: 'success',
          message: 'fieldlab.Admin/ListTenants · OK · 2 ms',
        },
      },
    })

    expect(wrapper.find('.bottom-status-message').text()).toContain('fieldlab.Admin/ListTenants')
    expect(wrapper.find('.bottom-status-result').text()).toBe('OK · 2 ms')
  })
})
