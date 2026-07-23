import {describe, expect, it, vi} from 'vitest'
import {mount} from '@vue/test-utils'
import ResponsePanel from './ResponsePanel.vue'

vi.mock('../../../wailsjs/runtime/runtime', () => ({
  ClipboardSetText: vi.fn(),
}))

describe('ResponsePanel', () => {
  it('renders empty response state', () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        response: null,
        isInvoking: false,
      },
    })

    expect(wrapper.text()).toContain('No response yet.')
    expect(wrapper.find('[aria-label="Open invocation history"]').exists()).toBe(true)
    expect(wrapper.find('[aria-label="Copy response body"]').exists()).toBe(false)
  })

  it('renders loading state', () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        response: null,
        isInvoking: true,
      },
    })

    expect(wrapper.text()).toContain('Invoking method...')
  })

  it('does not render response status or duration in the response column footer', () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        isInvoking: false,
        response: {
          ok: true,
          statusCode: 'OK',
          durationMs: 2,
          bodyJson: '{\n  "message": "hello",\n  "nested": {"ok": true}\n}',
        },
      },
    })

    expect(wrapper.find('.panel-header').text()).toContain('Response')
    expect(wrapper.find('.panel-header').text()).not.toContain('2 ms')
    expect(wrapper.find('.response-status-bar').text()).not.toContain('OK')
    expect(wrapper.find('.response-status-bar').text()).not.toContain('2 ms')
    expect(wrapper.text()).toContain('{')
    expect(wrapper.text()).toContain('}')
    expect(wrapper.find('.json-toggle').text()).toBe('-')
  })

  it('collapses response objects with an explicit plus control', async () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        isInvoking: false,
        response: {
          ok: true,
          statusCode: 'OK',
          durationMs: 2,
          bodyJson: '{\n  "message": "hello",\n  "nested": {"ok": true}\n}',
        },
      },
    })

    await wrapper.find('.json-toggle').trigger('click')

    expect(wrapper.find('.json-toggle').text()).toBe('+')
    expect(wrapper.text()).toContain('{')
    expect(wrapper.text()).toContain('}')
  })

  it('filters response tree with header search', async () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        isInvoking: false,
        response: {
          ok: true,
          statusCode: 'OK',
          durationMs: 2,
          bodyJson: '{\n  "message": "hello",\n  "traceId": "abc"\n}',
        },
      },
    })

    await wrapper.find('input[type="search"]').setValue('trace')

    expect(wrapper.text()).toContain('traceId')
    expect(wrapper.text()).not.toContain('message')
    expect(wrapper.find('.response-status-bar').text()).toContain('1 matches')
  })

  it('copies the raw response body from the status bar', async () => {
    const {ClipboardSetText} = await import('../../../wailsjs/runtime/runtime')
    const wrapper = mount(ResponsePanel, {
      props: {
        isInvoking: false,
        response: {
          ok: true,
          statusCode: 'OK',
          durationMs: 2,
          bodyJson: '{\n  "message": "hello"\n}',
        },
      },
    })

    await wrapper.find('[aria-label="Copy response body"]').trigger('click')

    expect(ClipboardSetText).toHaveBeenCalledWith('{\n  "message": "hello"\n}')
  })

  it('emits history open from the status bar', async () => {
    const wrapper = mount(ResponsePanel, {
      props: {
        response: null,
        isInvoking: false,
      },
    })

    await wrapper.find('[aria-label="Open invocation history"]').trigger('click')

    expect(wrapper.emitted('openHistory')).toHaveLength(1)
  })
})
