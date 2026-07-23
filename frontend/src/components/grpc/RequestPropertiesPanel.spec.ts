import {describe, expect, it} from 'vitest'
import {flushPromises, mount} from '@vue/test-utils'
import RequestPropertiesPanel from './RequestPropertiesPanel.vue'
import type {GrpcMethod} from '../../types/grpc'

const method: GrpcMethod = {
  serviceName: 'fieldlab.FieldLabService',
  methodName: 'Ping',
  fullName: '/fieldlab.FieldLabService/Ping',
  requestType: 'fieldlab.PingRequest',
  responseType: 'fieldlab.PingResponse',
  clientStreaming: false,
  serverStreaming: false,
  requestFields: [
    {
      name: 'who',
      jsonName: 'who',
      type: 'string',
      repeated: false,
      map: false,
    },
    {
      name: 'count',
      jsonName: 'count',
      type: 'int32',
      repeated: false,
      map: false,
    },
    {
      name: 'state',
      jsonName: 'state',
      type: 'enum',
      repeated: false,
      map: false,
      enumValues: ['UNKNOWN', 'ACTIVE'],
    },
    {
      name: 'scheduled_at',
      jsonName: 'scheduledAt',
      type: 'message',
      repeated: false,
      map: false,
      messageType: 'google.protobuf.Timestamp',
    },
  ],
}

describe('RequestPropertiesPanel', () => {
  it('moves invoke into the header and emits invoke from there', async () => {
    const wrapper = mount(RequestPropertiesPanel, {
      props: baseProps(),
    })

    const header = wrapper.find('.panel-header')
    expect(header.text()).toContain('Request')
    expect(header.text()).toContain('Invoke')
    expect(wrapper.find('.full-width-action').exists()).toBe(false)

    await header.find('button').trigger('click')

    expect(wrapper.emitted('invoke')).toHaveLength(1)
  })

  it('renders request fields and syncs scalar values into body JSON', async () => {
    const wrapper = mount(RequestPropertiesPanel, {
      props: baseProps(),
    })

    expect(wrapper.text()).toContain('who')
    expect(wrapper.text()).toContain('count')

    const inputs = wrapper.findAll('input.request-field-input')
    await inputs[0].setValue('Codex')
    await inputs[1].setValue('7')

    const updates = wrapper.emitted('update:bodyJson')
    expect(updates?.[0][0]).toContain('"who": "Codex"')
    expect(updates?.[1][0]).toContain('"count": 7')
  })

  it('renders enum fields with the shared input class', async () => {
    const wrapper = mount(RequestPropertiesPanel, {
      props: baseProps(),
    })

    const enumSelect = wrapper.find('select.request-field-input')
    expect(enumSelect.exists()).toBe(true)

    await enumSelect.setValue('ACTIVE')

    expect(wrapper.emitted('update:bodyJson')?.[0][0]).toContain('"state": "ACTIVE"')
  })

  it('edits timestamp fields with date and hour controls', async () => {
    const wrapper = mount(RequestPropertiesPanel, {
      props: {
        ...baseProps(),
        bodyJson: '{"scheduledAt":"2026-06-19T08:00:00Z"}',
      },
    })

    const dateInput = wrapper.find('[aria-label="Timestamp date"]')
    const calendarButton = wrapper.find('[aria-label="Open timestamp calendar"]')
    const hourInput = wrapper.find('input[type="range"]')
    const manualInput = wrapper.find('[aria-label="Timestamp value"]')

    expect(dateInput.exists()).toBe(true)
    expect(calendarButton.exists()).toBe(true)
    expect(hourInput.exists()).toBe(true)
    expect(manualInput.exists()).toBe(true)
    expect((dateInput.element as HTMLInputElement).value).toBe('2026/06/19')
    expect((hourInput.element as HTMLInputElement).value).toBe('8')
    expect((manualInput.element as HTMLInputElement).value).toBe('2026-06-19T08:00:00Z')

    await dateInput.setValue('2026/06/20')
    await hourInput.setValue('14')
    await manualInput.setValue('2026-06-21T14:37:45Z')
    await calendarButton.trigger('click')
    ;(document.querySelector('[data-date="2026-06-22"]') as HTMLButtonElement).click()
    await wrapper.vm.$nextTick()

    const updates = wrapper.emitted('update:bodyJson')
    expect(updates?.[0][0]).toContain('"scheduledAt": "2026-06-20T08:00:00Z"')
    expect(updates?.[1][0]).toContain('"scheduledAt": "2026-06-19T14:00:00Z"')
    expect(updates?.[2][0]).toContain('"scheduledAt": "2026-06-21T14:37:45Z"')
    expect(updates?.[3][0]).toContain('"scheduledAt": "2026-06-22T08:00:00Z"')
    wrapper.unmount()
  })

  it('keeps the request body in a modal opened from the bottom status bar', async () => {
    const wrapper = mount(RequestPropertiesPanel, {
      props: baseProps(),
      global: {
        stubs: {
          Teleport: true,
        },
      },
    })

    expect(wrapper.text()).not.toContain('fieldlab.FieldLabService')
    expect(wrapper.text()).not.toContain('fieldlab.PingRequest')
    expect(wrapper.find('.metadata-table').exists()).toBe(false)
    expect(wrapper.find('.call-options').exists()).toBe(false)
    expect(wrapper.find('.request-status-bar').text()).toContain('4 fields')
    expect(wrapper.find('.request-body-modal').exists()).toBe(false)

    await wrapper.find('.request-body-button').trigger('click')
    await flushPromises()

    expect(wrapper.find('.request-body-modal').exists()).toBe(true)
    expect(wrapper.find('.request-body-modal textarea').exists()).toBe(true)
  })
})

function baseProps() {
  return {
    selectedMethod: method,
    bodyJson: '{}',
    metadata: [],
    options: {timeoutMs: 5000, authority: ''},
    canInvoke: true,
    isInvoking: false,
  }
}
