import {describe, expect, it} from 'vitest'
import {mount} from '@vue/test-utils'
import RequestFieldEditor from './RequestFieldEditor.vue'
import type {GrpcField} from '../../types/grpc'

describe('RequestFieldEditor', () => {
  it('adds, edits, and removes scalar array items individually', async () => {
    const wrapper = mountEditor(repeatedField({type: 'string'}), [])

    await wrapper.find('.repeated-field-add').trigger('click')
    expect(lastValue(wrapper)).toEqual([''])

    await wrapper.setProps({value: ['']})
    await wrapper.find('input.request-field-input').setValue('alpha')
    expect(lastValue(wrapper)).toEqual(['alpha'])

    await wrapper.setProps({value: ['alpha']})
    await wrapper.find('[aria-label="Remove item 1"]').trigger('click')
    expect(lastValue(wrapper)).toEqual([])
  })

  it('uses enum, boolean, and wrapper scalar controls for array items', async () => {
    const enumWrapper = mountEditor(repeatedField({type: 'enum', enumValues: ['UNKNOWN', 'READY']}), [])
    await enumWrapper.find('.repeated-field-add').trigger('click')
    expect(lastValue(enumWrapper)).toEqual(['UNKNOWN'])
    await enumWrapper.setProps({value: ['UNKNOWN']})
    await enumWrapper.find('select').setValue('READY')
    expect(lastValue(enumWrapper)).toEqual(['READY'])

    const boolWrapper = mountEditor(repeatedField({type: 'bool'}), [false])
    await boolWrapper.find('input[type="checkbox"]').setValue(true)
    expect(lastValue(boolWrapper)).toEqual([true])

    const intWrapper = mountEditor(repeatedField({type: 'message', messageType: 'google.protobuf.Int32Value'}), [])
    await intWrapper.find('.repeated-field-add').trigger('click')
    expect(lastValue(intWrapper)).toEqual([0])
    await intWrapper.setProps({value: [0]})
    expect(intWrapper.find('input[type="number"]').exists()).toBe(true)
    await intWrapper.find('input[type="number"]').setValue('42')
    expect(lastValue(intWrapper)).toEqual([42])
  })

  it('edits repeated messages in structured form and JSON modes', async () => {
    const field = repeatedField({type: 'message', messageType: 'lab.Item'})
    const messageTypes = {
      'lab.Item': {
        fields: [scalarField('name', 'string'), scalarField('count', 'int32')],
      },
    }
    const wrapper = mount(RequestFieldEditor, {
      props: {field, value: [{}], messageTypes},
    })

    expect(wrapper.find('.message-mode-control button[data-active="true"]').text()).toContain('Form')
    await wrapper.find('.nested-field-row input[type="text"]').setValue('first')
    expect(lastValue(wrapper)).toEqual([{name: 'first'}])

    await wrapper.setProps({value: [{name: 'first'}]})
    const jsonButton = wrapper.findAll('.message-mode-control button').find((button) => button.text().includes('JSON'))
    await jsonButton!.trigger('click')
    const textarea = wrapper.find('textarea.request-field-json')
    expect((textarea.element as HTMLTextAreaElement).value).toContain('"name": "first"')
    await textarea.setValue('{"name":"second","count":2}')
    expect(lastValue(wrapper)).toEqual([{name: 'second', count: 2}])
  })

  it('keeps valid values when per-item JSON is invalid', async () => {
    const field = repeatedField({type: 'message', messageType: 'lab.Item'})
    const wrapper = mount(RequestFieldEditor, {
      props: {
        field,
        value: [{name: 'valid'}],
        messageTypes: {'lab.Item': {fields: [scalarField('name', 'string')]}},
      },
    })
    const jsonButton = wrapper.findAll('.message-mode-control button').find((button) => button.text().includes('JSON'))
    await jsonButton!.trigger('click')
    const emissionCount = wrapper.emitted('update:value')?.length ?? 0
    await wrapper.find('textarea.request-field-json').setValue('{invalid')

    expect(wrapper.find('.field-validation-error').exists()).toBe(true)
    expect(wrapper.emitted('update:value')?.length ?? 0).toBe(emissionCount)
  })

  it('falls back to JSON for recursive message references', () => {
    const field = repeatedField({type: 'message', messageType: 'lab.Node'})
    const messageTypes = {
      'lab.Node': {
        fields: [
          scalarField('name', 'string'),
          {...scalarField('next', 'message'), messageType: 'lab.Node'},
        ],
      },
    }
    const wrapper = mount(RequestFieldEditor, {
      props: {field, value: [{name: 'root', next: {}}], messageTypes},
    })

    expect(wrapper.findAll('.message-mode-control')).toHaveLength(1)
    expect(wrapper.find('.nested-field-row textarea.request-field-json').exists()).toBe(true)
  })

  it('closes the timestamp calendar after selecting a date', async () => {
    const wrapper = mountEditor(timestampField(), '2026-06-19T14:00:00Z')

    await wrapper.find('[aria-label="Open timestamp calendar"]').trigger('click')
    expect(document.querySelector('.timestamp-calendar-popover')).not.toBeNull()

    ;(document.querySelector('[data-date="2026-06-20"]') as HTMLButtonElement).click()
    await wrapper.vm.$nextTick()

    expect(lastValue(wrapper)).toBe('2026-06-20T14:00:00Z')
    expect(document.querySelector('.timestamp-calendar-popover')).toBeNull()
    wrapper.unmount()
  })

  it('closes the timestamp calendar after an outside click', async () => {
    const wrapper = mountEditor(timestampField(), '2026-06-19T14:00:00Z')

    await wrapper.find('[aria-label="Open timestamp calendar"]').trigger('click')
    document.body.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}))
    await wrapper.vm.$nextTick()

    expect(document.querySelector('.timestamp-calendar-popover')).toBeNull()
    wrapper.unmount()
  })
})

function mountEditor(field: GrpcField, value: unknown) {
  return mount(RequestFieldEditor, {props: {field, value}})
}

function repeatedField(patch: Partial<GrpcField>): GrpcField {
  return {
    name: 'items',
    jsonName: 'items',
    type: 'string',
    repeated: true,
    map: false,
    ...patch,
  }
}

function scalarField(name: string, type: string): GrpcField {
  return {name, jsonName: name, type, repeated: false, map: false}
}

function timestampField(): GrpcField {
  return {
    name: 'created_at',
    jsonName: 'createdAt',
    type: 'message',
    messageType: 'google.protobuf.Timestamp',
    repeated: false,
    map: false,
  }
}

function lastValue(wrapper: ReturnType<typeof mount>): unknown {
  return wrapper.emitted('update:value')?.at(-1)?.[0]
}
